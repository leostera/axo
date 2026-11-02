import { TableOfContents, useTableOfContentsActiveId } from "@cloudflare/kumo";

export interface TocHeading {
  slug: string;
  text: string;
}

const HEADER_OFFSET = 88;

/** Section navigation with scrollspy. Server-rendered, then hydrated for the active state. */
export function Toc({ title, headings }: { title: string; headings: TocHeading[] }) {
  const { activeId, selectSection } = useTableOfContentsActiveId({
    ids: headings.map((heading) => heading.slug),
    offset: HEADER_OFFSET,
  });
  return (
    <TableOfContents>
      <TableOfContents.Title>{title}</TableOfContents.Title>
      <TableOfContents.List>
        {headings.map((heading) => (
          <TableOfContents.Item
            key={heading.slug}
            href={`#${heading.slug}`}
            active={activeId === heading.slug}
            onClick={() => selectSection(heading.slug)}
          >
            {heading.text}
          </TableOfContents.Item>
        ))}
      </TableOfContents.List>
    </TableOfContents>
  );
}
