/**
 * Fetch a complete Supabase/PostgREST result set despite the API row cap.
 * The query factory must return a fresh query builder for each requested range
 * and use deterministic ordering when rows can be inserted during pagination.
 */
export async function fetchAllRows(queryPage, pageSize = 1000) {
  if (typeof queryPage !== 'function') {
    throw new TypeError('queryPage must be a function');
  }
  if (!Number.isInteger(pageSize) || pageSize < 1) {
    throw new RangeError('pageSize must be a positive integer');
  }

  const rows = [];
  for (let from = 0; ; from += pageSize) {
    const { data, error } = await queryPage(from, from + pageSize - 1);
    if (error) throw error;
    if (!Array.isArray(data)) {
      throw new TypeError('Supabase page did not return a row array');
    }
    rows.push(...data);
    if (data.length < pageSize) return rows;
  }
}
