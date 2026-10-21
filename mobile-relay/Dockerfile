FROM node:24.22.1-alpine
ENV NODE_ENV=production BIND_ADDRESS=0.0.0.0 PORT=8080
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts && npm cache clean --force
COPY server.mjs ./
USER node
EXPOSE 8080
CMD ["node", "server.mjs"]
