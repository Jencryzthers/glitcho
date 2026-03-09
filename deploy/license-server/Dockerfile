FROM node:20-alpine

WORKDIR /app
COPY Scripts/license_server_example.mjs /app/license_server.mjs

USER node
EXPOSE 8787

ENV PORT=8787
CMD ["node", "/app/license_server.mjs"]
