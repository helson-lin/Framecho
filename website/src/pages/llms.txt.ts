import type { APIRoute } from 'astro';
import { getAbsoluteLocaleUrl } from 'astro:i18n';
import { ui } from '../i18n/ui';
import { faqAnswers } from '../seo';
import { links, release } from '../site';

// A plain-text summary for AI assistants (https://llmstxt.org): the same facts as the pages,
// without layout, so an assistant can quote them accurately.
const strip = (html: string) => html.replace(/<br>/g, ' ').replace(/<[^>]+>/g, '').replace(/\s+/g, ' ').trim();

export const GET: APIRoute = () => {
  const en = ui.en;
  const zh = ui.zh;
  const qa = (lang: 'en' | 'zh') => faqAnswers(lang).map(({ question, answer }) => `### ${question}\n\n${answer}`).join('\n\n');

  const body = `# Framecho

> ${en.meta.description}

- Latest version: ${release.version} (released ${release.date})
- Requires: macOS ${release.minimumMacOS} or later, Apple silicon or Intel
- Price: free; source code under CC0 1.0
- Interface languages: English, Simplified Chinese
- Download: ${links.download}
- Source code: ${links.repo}
- Author: helson-lin (${links.author})

## Pages

- [Framecho (English)](${getAbsoluteLocaleUrl('en')}): product overview, features and FAQ
- [Framecho（简体中文）](${getAbsoluteLocaleUrl('zh')}): 产品介绍、功能和常见问题
- [Release notes](${links.releases}): changes in every version
- [Framecho-worker](${links.worker}): the self-hosted Cloudflare service used for sharing

## Features

### ${strip(en.editor.kicker)}

${strip(en.editor.ledeHtml)}

${en.editor.features.map((f) => `- ${f.key}: ${strip(f.valueHtml)}`).join('\n')}
- Annotation tools (single-key shortcuts): ${en.editor.tools.map((tool, i) => `${tool} (${['I', 'N', 'R', 'F', 'P', 'B', 'M'][i]})`).join(', ')}

### ${en.studio.kicker}

${en.studio.lede}

${en.studio.features.map((f) => `- ${f.title}: ${f.body}`).join('\n')}

### Library and capture

${[en.library.library, en.library.pin, en.library.ocr, en.library.cjk, en.library.redact].map((f) => `- ${f.title}: ${f.body}`).join('\n')}
- Global shortcuts: ${en.rail.keys.map((key, i) => `⌥${i + 1} ${key}`).join(', ')}

### ${en.agents.kicker}

${strip(en.agents.ledeHtml)}

### ${en.privacy.kicker}

${en.privacy.tiles.map((tile) => `- ${tile.title}: ${tile.body}`).join('\n')}

## FAQ

${qa('en')}

## 简体中文

${zh.meta.description}

${qa('zh')}
`;

  return new Response(body, { headers: { 'Content-Type': 'text/plain; charset=utf-8' } });
};
