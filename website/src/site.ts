import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const repo = 'https://github.com/helson-lin/Framecho';

export const links = {
  repo,
  download: `${repo}/releases/latest/download/Framecho.dmg`,
  releases: `${repo}/releases`,
  issues: `${repo}/issues`,
  worker: 'https://github.com/helson-lin/Framecho-worker',
  screendrop: 'https://github.com/fayazara/screendrop',
};

/**
 * Reads a build setting from the Xcode project, so the page shows the version being
 * released without editing it by hand. Builds run from `website/`, beside the project.
 */
function buildSetting(name: string, fallback: string): string {
  try {
    const project = readFileSync(resolve(process.cwd(), '../Framecho.xcodeproj/project.pbxproj'), 'utf8');
    return project.match(new RegExp(`${name} = ([^;]+);`))?.[1].trim() ?? fallback;
  } catch {
    return fallback;
  }
}

export const version = buildSetting('MARKETING_VERSION', '0.44.0');
export const minimumMacOS = buildSetting('MACOSX_DEPLOYMENT_TARGET', '26.4');
