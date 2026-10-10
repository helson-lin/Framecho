import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';

const repo = 'https://github.com/helson-lin/Framecho';

export const links = {
  repo,
  download: `${repo}/releases/latest/download/Framecho.dmg`,
  releases: `${repo}/releases`,
  issues: `${repo}/issues`,
  license: `${repo}/blob/main/LICENSE`,
  worker: 'https://github.com/helson-lin/Framecho-worker',
  screendrop: 'https://github.com/fayazara/screendrop',
  author: 'https://github.com/helson-lin',
};

export interface Release {
  version: string;
  minimumMacOS: string;
  /** ISO 8601 date of the release. */
  date: string;
  /** Size of the DMG in bytes. */
  size: number;
}

const fallback: Release = { version: '0.44.0', minimumMacOS: '26.4', date: '2026-10-10', size: 10218756 };

/** The newest release in the Sparkle appcast, which is what users are actually offered. */
function parseAppcast(xml: string): Release | undefined {
  const item = xml.match(/<item>([\s\S]*?)<\/item>/)?.[1];
  if (!item) return undefined;
  const tag = (name: string) => item.match(new RegExp(`<${name}>([^<]+)</${name}>`))?.[1].trim();
  const version = tag('sparkle:shortVersionString');
  const pubDate = tag('pubDate');
  if (!version || !pubDate) return undefined;
  return {
    version,
    minimumMacOS: tag('sparkle:minimumSystemVersion') ?? fallback.minimumMacOS,
    date: new Date(pubDate).toISOString().slice(0, 10),
    size: Number(item.match(/length="(\d+)"/)?.[1] ?? fallback.size),
  };
}

/**
 * Reads the appcast beside the site when the whole repository is checked out, and from GitHub
 * when only `website/` was uploaded (as `vercel deploy` from this folder does).
 */
async function loadRelease(): Promise<Release> {
  try {
    const local = parseAppcast(await readFile(resolve(process.cwd(), '../appcast.xml'), 'utf8'));
    if (local) return local;
  } catch {}
  try {
    const response = await fetch('https://raw.githubusercontent.com/helson-lin/Framecho/main/appcast.xml');
    const remote = response.ok ? parseAppcast(await response.text()) : undefined;
    if (remote) return remote;
  } catch {}
  console.warn(`[framecho] Could not read appcast.xml; showing version ${fallback.version}.`);
  return fallback;
}

export const release = await loadRelease();
export const { version, minimumMacOS } = release;
