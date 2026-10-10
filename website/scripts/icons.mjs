// Renders public/favicon.ico (16, 32 and 48 px) and public/apple-touch-icon.png from
// public/favicon.svg. Run with `npm run icons` after changing the SVG.
import sharp from 'sharp';
import { readFile, writeFile } from 'node:fs/promises';

const svg = await readFile('public/favicon.svg');
const png = (size) => sharp(svg, { density: 72 * (size / 64) * 4 }).resize(size, size).png().toBuffer();

// An ICO file is a small directory of images; modern ICOs may store each one as a PNG.
const sizes = [16, 32, 48];
const images = await Promise.all(sizes.map(png));
const header = Buffer.alloc(6 + 16 * sizes.length);
header.writeUInt16LE(0, 0);
header.writeUInt16LE(1, 2);
header.writeUInt16LE(sizes.length, 4);
let offset = header.length;
sizes.forEach((size, i) => {
  const entry = 6 + 16 * i;
  header.writeUInt8(size, entry);
  header.writeUInt8(size, entry + 1);
  header.writeUInt16LE(1, entry + 4);
  header.writeUInt16LE(32, entry + 6);
  header.writeUInt32LE(images[i].length, entry + 8);
  header.writeUInt32LE(offset, entry + 12);
  offset += images[i].length;
});
await writeFile('public/favicon.ico', Buffer.concat([header, ...images]));

// iOS rounds the corners itself and shows transparency as black, so this one is square and opaque.
const touch = Buffer.from(
  svg.toString().replace('<rect width="64" height="64" rx="15"', '<rect width="64" height="64"'),
);
await sharp(touch, { density: 72 * (180 / 64) * 4 }).resize(180, 180).flatten({ background: '#ff5a36' }).png().toFile('public/apple-touch-icon.png');

console.log('public/favicon.ico, public/apple-touch-icon.png');
