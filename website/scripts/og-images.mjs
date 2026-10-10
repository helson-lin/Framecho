// Renders the 1200 × 630 Open Graph images into public/og/. Run with `npm run og` after changing the
// headline or the hero screenshot. They're rendered here rather than at build time because the
// headline needs the macOS system fonts, which a Linux build machine doesn't have.
import sharp from 'sharp';
import { mkdir } from 'node:fs/promises';

const W = 1200;
const H = 630;
const paper = '#f5f3ef';
const ink = '#17161a';
const ink2 = '#4a4850';
const ink3 = '#8a8790';
const accent = '#ff5a36';
const sans = "'SF Pro Display', 'PingFang SC', 'Helvetica Neue', sans-serif";

const variants = {
  zh: {
    shot: 'src/assets/editor-light.webp',
    lines: [[{ text: '一键截下，' }], [{ text: '把' }, { text: '重点', mark: true }, { text: '讲清楚。' }]],
    size: 74,
    sub: '原生 macOS 截图、录屏与编辑工具',
    foot: 'getframecho.com · 免费开源',
  },
  en: {
    shot: 'src/assets/editor-en-light.webp',
    lines: [[{ text: 'Capture it.' }], [{ text: 'Make the ' }, { text: 'point', mark: true }], [{ text: 'clear.' }]],
    size: 62,
    sub: 'Screenshot, record and edit on Mac',
    foot: 'getframecho.com · Free and open source',
  },
};

const escape = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;');

function headline({ lines, size }, top) {
  const lineHeight = size * 1.12;
  return lines
    .map((runs, i) => {
      const y = top + i * lineHeight;
      const spans = runs
        .map((run) => `<tspan fill="${run.mark ? accent : ink}">${escape(run.text)}</tspan>`)
        .join('');
      return `<text xml:space="preserve" x="72" y="${y}" font-family="${sans}" font-size="${size}" font-weight="800" letter-spacing="${-size * 0.03}">${spans}</text>`;
    })
    .join('');
}

async function render(lang, v) {
  const shotWidth = 720;
  const shot = await sharp(v.shot).resize({ width: shotWidth }).toBuffer();
  const { height: shotHeight } = await sharp(shot).metadata();
  const radius = 16;
  const mask = Buffer.from(`<svg width="${shotWidth}" height="${shotHeight}"><rect width="${shotWidth}" height="${shotHeight}" rx="${radius}"/></svg>`);
  const rounded = await sharp(shot).composite([{ input: mask, blend: 'dest-in' }]).png().toBuffer();
  const shotX = 560;
  const shotY = 150;

  const lineCount = v.lines.length;
  const headTop = lineCount === 2 ? 250 : 220;
  const subY = headTop + (lineCount - 1) * v.size * 1.12 + 70;

  const base = `<svg width="${W}" height="${H}" xmlns="http://www.w3.org/2000/svg">
    <defs>
      <filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">
        <feDropShadow dx="0" dy="30" stdDeviation="30" flood-color="#281e14" flood-opacity="0.28"/>
      </filter>
    </defs>
    <rect width="${W}" height="${H}" fill="${paper}"/>
    <rect x="${shotX}" y="${shotY}" width="${shotWidth}" height="${shotHeight}" rx="${radius}" fill="#fff" filter="url(#shadow)"/>
  </svg>`;

  // The top corners of the app icon's viewfinder; the bottom ones would fall below the image.
  const c = 34, w = 6, o = 18;
  const corners = (x, y, w0) => `
    <path d="M${x - o} ${y - o + c}V${y - o}H${x - o + c}" />
    <path d="M${x + w0 + o - c} ${y - o}H${x + w0 + o}V${y - o + c}" />`;
  const overlay = `<svg width="${W}" height="${H}" xmlns="http://www.w3.org/2000/svg">
    <g fill="none" stroke="${accent}" stroke-width="${w}" stroke-linecap="round" stroke-linejoin="round">${corners(shotX, shotY, shotWidth)}</g>
    <text x="146" y="104" font-family="${sans}" font-size="34" font-weight="700" fill="${ink}" letter-spacing="-0.5">Framecho</text>
    ${headline(v, headTop)}
    <text x="72" y="${subY}" font-family="${sans}" font-size="25" font-weight="500" fill="${ink2}">${escape(v.sub)}</text>
    <text x="72" y="566" font-family="'SF Mono', Menlo, monospace" font-size="19" font-weight="600" fill="${ink3}">${escape(v.foot)}</text>
  </svg>`;

  const icon = await sharp('src/assets/icon.png').resize(84).toBuffer();

  await mkdir('public/og', { recursive: true });
  await sharp(Buffer.from(base))
    .composite([
      { input: rounded, left: shotX, top: shotY },
      { input: Buffer.from(overlay), left: 0, top: 0 },
      { input: icon, left: 52, top: 50 },
    ])
    .png({ compressionLevel: 9, palette: false })
    .toFile(`public/og/${lang}.png`);
  console.log(`public/og/${lang}.png`);
}

for (const [lang, v] of Object.entries(variants)) await render(lang, v);
