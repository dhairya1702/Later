import Photos
import SwiftData

/// How an ingestion route resolved to an item. Only `created` represents a genuinely
/// new thing worth telling the user about; `merged` means the other route already
/// announced this screenshot.
enum ItemResolution {
    case created(LaterItem)
    case merged(LaterItem)
    case existing(LaterItem)

    var item: LaterItem {
        switch self {
        case .created(let item), .merged(let item), .existing(let item): item
        }
    }

    var isNew: Bool {
        if case .created = self { return true }
        return false
    }
}

@MainActor
struct ItemRepository {
    let context: ModelContext

    func item(for assetIdentifier: String) throws -> LaterItem? {
        var descriptor = FetchDescriptor<LaterItem>(
            predicate: #Predicate { $0.screenshotAssetIdentifier == assetIdentifier }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func item(withID id: UUID) throws -> LaterItem? {
        var descriptor = FetchDescriptor<LaterItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func resolve(
        for asset: PHAsset,
        text: String,
        classification: ClassificationResult,
        fingerprint: ScreenshotFingerprint?
    ) throws -> ItemResolution {
        if try item(for: asset.localIdentifier) != nil {
            return .existing(try createIfNeeded(for: asset, text: text, classification: classification))
        }

        // The user may have shared this screenshot moments ago. Give the shared item
        // its Photos identity rather than creating a second item for the same pixels.
        if let fingerprint,
           let canonical = try CanonicalItemResolver(context: context)
            .canonicalItem(for: fingerprint, arrivingFrom: .photoLibrary) {
            canonical.screenshotAssetIdentifier = asset.localIdentifier
            canonical.createdAt = asset.creationDate ?? canonical.createdAt
            canonical.updatedAt = .now
            try context.save()
            return .merged(canonical)
        }

        return .created(try createIfNeeded(for: asset, text: text, classification: classification))
    }

    func createIfNeeded(
        for asset: PHAsset,
        text: String,
        classification: ClassificationResult
    ) throws -> LaterItem {
        let title = classification.suggestedTitle ?? TitleExtractor().extract(
            from: text,
            category: classification.category,
            screenDetection: classification.screenDetection
        )
        if let existing = try item(for: asset.localIdentifier) {
            if !existing.isUserCorrected {
                existing.title = title
                existing.subtitle = classification.summary
                existing.category = classification.category
                existing.kind = classification.kind
                existing.confidence = classification.confidence
                existing.needsReview = classification.needsReview
                existing.updatedAt = .now
            }
            applyMetadata(classification, to: existing)
            try context.save()
            return existing
        }

        let item = LaterItem(
            title: title,
            category: classification.category,
            kind: classification.kind,
            confidence: classification.confidence,
            createdAt: asset.creationDate ?? .now,
            screenshotAssetIdentifier: asset.localIdentifier,
            rawOCRText: text,
            needsReview: classification.needsReview
        )
        item.subtitle = classification.summary
        applyMetadata(classification, to: item)
        context.insert(item)
        try context.save()
        return item
    }

    func resolve(
        from record: ShareInboxRecord,
        classification: ClassificationResult,
        fingerprint: ScreenshotFingerprint?
    ) throws -> ItemResolution {
        if let existing = try item(withID: record.id) { return .existing(existing) }

        // Photos discovery may have reached this screenshot first. Attach the shared
        // copy to that item instead of standing up a second one beside it.
        if let fingerprint,
           let canonical = try CanonicalItemResolver(context: context)
            .canonicalItem(for: fingerprint, arrivingFrom: .share) {
            canonical.sharedImageFilename = record.imageFilename
            canonical.updatedAt = .now
            try context.save()
            return .merged(canonical)
        }

        let item = LaterItem(
            id: record.id,
            title: classification.suggestedTitle ?? "Saved screenshot",
            category: classification.category,
            kind: classification.kind,
            confidence: classification.confidence,
            createdAt: record.createdAt,
            screenshotAssetIdentifier: LaterItem.sharedIdentifier(for: record.id),
            rawOCRText: record.analysis?.visibleText ?? "",
            needsReview: classification.needsReview
        )
        item.subtitle = classification.summary
        item.sharedImageFilename = record.imageFilename
        applyMetadata(classification, to: item)
        context.insert(item)
        try context.save()
        return .created(item)
    }

    private func applyMetadata(_ classification: ClassificationResult, to item: LaterItem) {
        item.visualLabelsText = classification.visualLabels?
            .prefix(5)
            .map(\.identifier)
            .joined(separator: ", ")
        item.isVisualOnly = classification.usedVisualClassification
        item.screenSurfaceRaw = classification.screenDetection?.surface.rawValue
        item.sourceAppRaw = classification.screenDetection?.sourceApp.rawValue
        item.screenDetectionConfidence = classification.screenDetection?.confidence
        item.screenDetectionEvidenceText = classification.screenDetection?.evidence.joined(separator: ", ")
        item.isOffer = classification.category == .offer || (classification.offerConfidence ?? 0) >= 0.5

        let actionableEntities = validatedEntities(classification.actionableEntities ?? [])
        item.actionableEntitiesJSON = try? JSONEncoder().encode(actionableEntities)
        item.detectedURL = actionableEntities.first(where: { $0.type == .url })?.value
        item.detectedMediaJSON = validatedMedia(classification.detectedMedia)
            .flatMap { try? JSONEncoder().encode($0) }
        item.productDetailsJSON = validatedProduct(classification.productDetails)
            .flatMap { try? JSONEncoder().encode($0) }

        guard let facts = classification.facts else { return }
        item.detectedDate = facts.primaryDate
        let hasAmbiguousDates = facts.primaryDate == nil
            && facts.primaryDateRole == nil
            && facts.dateTexts.count > 1
        item.detectedDateText = hasAmbiguousDates ? nil : facts.dateTexts.first
        item.detectedTimeText = hasAmbiguousDates ? nil : facts.timeTexts.first
        item.detectedLocation = facts.locations.first
        item.couponCode = facts.couponCodes.first
        item.discountText = facts.discountTexts.first
        item.importantDateRole = facts.primaryDateRole
        item.metadataJSON = try? JSONEncoder().encode(facts)

        if let price = facts.prices.first {
            item.detectedPrice = numericPrice(from: price)
            item.detectedCurrency = currency(from: price)
        }
    }

    private func numericPrice(from text: String) -> Double? {
        let cleaned = text.replacingOccurrences(
            of: #"[^0-9.]"#,
            with: "",
            options: .regularExpression
        )
        return Double(cleaned)
    }

    private func currency(from text: String) -> String? {
        let uppercased = text.uppercased()
        if uppercased.contains("$") || uppercased.contains("USD") { return "USD" }
        if uppercased.contains("€") || uppercased.contains("EUR") { return "EUR" }
        if uppercased.contains("£") || uppercased.contains("GBP") { return "GBP" }
        if uppercased.contains("₹") || uppercased.contains("INR") { return "INR" }
        return nil
    }

    private func validatedEntities(_ entities: [ActionableEntity]) -> [ActionableEntity] {
        var seen = Set<String>()
        return entities.compactMap { entity in
            guard entity.confidence >= 0.8,
                  let value = validatedValue(for: entity) else { return nil }
            let key = "\(entity.type.rawValue):\(value.lowercased())"
            guard seen.insert(key).inserted else { return nil }
            return ActionableEntity(
                type: entity.type,
                value: value,
                confidence: entity.confidence,
                evidence: entity.evidence
            )
        }
    }

    private func validatedMedia(_ media: DetectedMedia?) -> DetectedMedia? {
        guard let media, media.confidence >= 0.8 else { return nil }
        let title = media.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let creator = media.creator.trimmingCharacters(in: .whitespacesAndNewlines)
        let evidence = media.evidence
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard title.count >= 2, creator.count >= 2, !evidence.isEmpty else { return nil }

        let groundedText = evidence.joined(separator: " ").folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        let groundedTitle = title.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        let groundedCreator = creator.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        guard groundedText.contains(groundedTitle), groundedText.contains(groundedCreator) else { return nil }

        return DetectedMedia(
            type: media.type,
            title: title,
            creator: creator,
            sourceService: media.sourceService,
            confidence: media.confidence,
            evidence: evidence
        )
    }

    private func validatedProduct(_ product: DetectedProductDetails?) -> DetectedProductDetails? {
        guard let product, product.confidence >= 0.8 else { return nil }
        let name = product.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let evidence = product.evidence
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard name.count >= 2, !evidence.isEmpty else { return nil }
        let groundedEvidence = evidence.joined(separator: " ").folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: .current
        )
        let groundedName = name.folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: .current
        )
        guard groundedEvidence.contains(groundedName) else { return nil }
        func grounded(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let normalized = trimmed.folding(
                options: [.caseInsensitive, .diacriticInsensitive], locale: .current
            )
            return groundedEvidence.contains(normalized) ? trimmed : nil
        }
        return DetectedProductDetails(
            name: name,
            brand: grounded(product.brand),
            model: grounded(product.model),
            variant: grounded(product.variant),
            currentPrice: grounded(product.currentPrice),
            originalPrice: grounded(product.originalPrice),
            discount: grounded(product.discount),
            seller: grounded(product.seller),
            condition: grounded(product.condition),
            negotiable: grounded(product.negotiable),
            rating: grounded(product.rating),
            reviewCount: grounded(product.reviewCount),
            delivery: grounded(product.delivery),
            availability: grounded(product.availability),
            fulfillment: grounded(product.fulfillment),
            location: grounded(product.location),
            confidence: product.confidence,
            evidence: evidence
        )
    }

    private func validatedValue(for entity: ActionableEntity) -> String? {
        let value = entity.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let evidence = entity.evidence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !evidence.isEmpty else { return nil }

        switch entity.type {
        case .phone:
            let digits = value.filter(\.isNumber)
            let evidenceDigits = evidence.filter(\.isNumber)
            guard (7...15).contains(digits.count), evidenceDigits.contains(digits) else { return nil }
            return value.hasPrefix("+") ? "+\(digits)" : digits
        case .email:
            let normalized = value.lowercased()
            guard normalized.range(
                of: #"^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil,
                  evidence.lowercased().contains(normalized) else { return nil }
            return normalized
        case .url:
            let candidate = value.contains("://") ? value : "https://\(value)"
            guard let components = URLComponents(string: candidate),
                  let host = components.host, host.contains(".") else { return nil }
            let groundedHost = host.lowercased().replacingOccurrences(of: "www.", with: "")
            guard evidence.lowercased().contains(groundedHost) else { return nil }
            return components.url?.absoluteString
        case .address:
            let normalizedValue = value.lowercased().filter { $0.isLetter || $0.isNumber }
            let normalizedEvidence = evidence.lowercased().filter { $0.isLetter || $0.isNumber }
            guard normalizedValue.count >= 6,
                  normalizedEvidence.contains(normalizedValue) else { return nil }
            return value
        case .couponCode:
            guard evidence.uppercased().contains(value.uppercased()) else { return nil }
            return value
        }
    }
}
