import type { APIRoute } from 'astro';

// Search engines and AI crawlers alike are welcome: the page and /llms.txt exist to be read.
const crawlers = ['*', 'GPTBot', 'OAI-SearchBot', 'ChatGPT-User', 'ClaudeBot', 'Claude-SearchBot', 'PerplexityBot', 'Google-Extended', 'Applebot-Extended'];

export const GET: APIRoute = ({ site }) => {
  const rules = crawlers.map((agent) => `User-agent: ${agent}\nAllow: /`).join('\n\n');
  const body = `${rules}\n\nSitemap: ${new URL('sitemap-index.xml', site)}\n`;
  return new Response(body, { headers: { 'Content-Type': 'text/plain; charset=utf-8' } });
};
