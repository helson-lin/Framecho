// Structured data and plain-text summaries built from the page copy, so search engines and
// AI assistants are given exactly what the page says.
import { ui, type Locale } from './i18n/ui';
import { links, release } from './site';

export function faqAnswers(lang: Locale) {
  return ui[lang].faq.items.map((item) => ({
    question: item.q,
    answer: typeof item.a === 'function' ? item.a(release.minimumMacOS) : item.a,
  }));
}

const megabytes = (bytes: number) => `${(bytes / 1_000_000).toFixed(1)} MB`;

interface StructuredDataOptions {
  lang: Locale;
  pageUrl: string;
  siteUrl: string;
  ogImage: string;
  screenshots: string[];
}

/** One JSON-LD graph per page: the app, the site and the page's FAQ. */
export function structuredData({ lang, pageUrl, siteUrl, ogImage, screenshots }: StructuredDataOptions) {
  const t = ui[lang];
  const appId = `${siteUrl}#app`;
  const authorId = `${siteUrl}#author`;
  return {
    '@context': 'https://schema.org',
    '@graph': [
      {
        '@type': 'SoftwareApplication',
        '@id': appId,
        name: 'Framecho',
        description: t.meta.description,
        url: pageUrl,
        applicationCategory: 'MultimediaApplication',
        applicationSubCategory: t.seo.applicationSubCategory,
        operatingSystem: t.seo.operatingSystem(release.minimumMacOS),
        processorRequirements: 'Apple silicon or Intel',
        softwareVersion: release.version,
        dateModified: release.date,
        downloadUrl: links.download,
        installUrl: links.download,
        releaseNotes: links.releases,
        fileSize: megabytes(release.size),
        inLanguage: ['en', 'zh-CN'],
        isAccessibleForFree: true,
        offers: { '@type': 'Offer', price: '0', priceCurrency: 'USD' },
        license: 'https://creativecommons.org/publicdomain/zero/1.0/',
        image: ogImage,
        screenshot: screenshots,
        featureList: [
          ...t.studio.features.map((feature) => feature.title),
          t.library.library.title,
          t.library.pin.title,
          t.library.ocr.title,
          t.library.redact.title,
        ],
        author: { '@id': authorId },
        sameAs: [links.repo],
      },
      {
        '@type': 'Person',
        '@id': authorId,
        name: 'helson-lin',
        url: links.author,
      },
      {
        '@type': 'WebSite',
        '@id': `${siteUrl}#website`,
        name: 'Framecho',
        url: siteUrl,
        inLanguage: ['zh-CN', 'en'],
        about: { '@id': appId },
      },
      {
        '@type': 'FAQPage',
        '@id': `${pageUrl}#faq`,
        url: pageUrl,
        inLanguage: t.htmlLang,
        about: { '@id': appId },
        mainEntity: faqAnswers(lang).map(({ question, answer }) => ({
          '@type': 'Question',
          name: question,
          acceptedAnswer: { '@type': 'Answer', text: answer },
        })),
      },
    ],
  };
}
