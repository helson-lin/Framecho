// @ts-check
import { defineConfig } from 'astro/config';

export default defineConfig({
  // Absolute URLs (canonical, hreflang) are only emitted when the deployed origin is known.
  site: process.env.SITE_URL,
  i18n: {
    defaultLocale: 'zh',
    locales: ['zh', 'en'],
    routing: {
      // Chinese is served from `/`, English from `/en/`.
      prefixDefaultLocale: false,
    },
  },
});
