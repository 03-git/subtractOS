---
aliases: api pagination, cursor pagination, paginate api results, next page token, api paging, iterate api pages
tags: api, pagination, integration, http
verified: false
source: Common API patterns (Stripe, Slack, GitHub)
---

HANDLE CURSOR-BASED API PAGINATION

Steps:
1. Make the initial request with your query parameters. Include a page size if the API supports it (e.g., `limit=100`).
2. In the response, look for a cursor/pagination indicator. Common patterns:
   - `next_cursor` or `cursor` field in the response body
   - `has_more: true/false` boolean
   - `Link` header with `rel="next"` (RFC 8288)
   - `next_page_token` field
3. If more pages exist: take the cursor value and include it in the next request (e.g., `?cursor=CURSOR_VALUE&limit=100`).
4. Accumulate results from each page into your collection.
5. Stop when: `has_more` is false, `next_cursor` is null/empty, or no `Link: rel="next"` header is present.
6. Handle rate limits: if you receive 429 Too Many Requests, read the `Retry-After` header (seconds or HTTP date). Wait that duration before retrying. Do not retry immediately.
7. Handle partial failures: if a page request fails with 5xx, retry with exponential backoff (1s, 2s, 4s, max 3 retries). Resume from the last successful cursor, not from the beginning.

Notes:
- Never assume page order is stable across requests unless the API guarantees it. Some APIs return different results if the underlying data changes between pages.
- Cursor pagination is preferred over offset pagination for large datasets. Offset skips become expensive at high page numbers.
- Some APIs use opaque cursors (base64 encoded). Do not decode or construct cursors -- treat them as opaque strings.
- If the API returns a total count, use it for progress indication only. Do not use it to calculate the number of pages -- the count can change during pagination.
