FROM node:20-alpine

WORKDIR /app
COPY apps/commerce/package*.json ./
RUN npm ci --omit=dev

COPY apps/commerce/ ./

RUN mkdir -p /data
ENV NODE_ENV=production
ENV PORT=8080
ENV DATA_DIR=/data

EXPOSE 8080
CMD ["npm", "start"]
