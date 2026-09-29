FROM node:22-slim

ENV NODE_ENV=production
WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY analyze.mjs apns.mjs security.mjs server.mjs Apple_App_Attestation_Root_CA.pem ./

USER node
EXPOSE 8080
CMD ["node", "server.mjs"]
