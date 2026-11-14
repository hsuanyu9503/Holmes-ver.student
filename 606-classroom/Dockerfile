FROM node:22-alpine
ENV NODE_ENV=production PORT=3606 DATA_DIR=/data
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force
COPY server ./server
COPY public ./public
RUN mkdir -p /data && chown node:node /data
USER node
VOLUME ["/data"]
EXPOSE 3606
HEALTHCHECK --interval=30s --timeout=3s CMD wget -qO- http://127.0.0.1:3606/healthz || exit 1
CMD ["node", "server/index.js"]
