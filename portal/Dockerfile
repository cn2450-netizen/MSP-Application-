FROM node:22-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY tsconfig.json next.config.mjs ./
COPY src ./src
RUN npm run build && npm prune --omit=dev

FROM node:22-alpine
ENV NODE_ENV=production NEXT_TELEMETRY_DISABLED=1
WORKDIR /app
COPY --from=build /app/package.json ./
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/.next ./.next
COPY next.config.mjs ./
COPY migrations ./migrations
COPY scripts ./scripts
USER node
EXPOSE 3000
CMD ["sh", "-c", "node scripts/migrate.mjs && exec node_modules/.bin/next start -p 3000"]
