const TABLES = {
  quote_appointments: new Set([
    "id", "location", "appointment_date", "appointment_time", "client_name",
    "address", "notes", "salesperson", "is_blocked", "is_all_day_block",
    "property_count", "created_at"
  ]),
  quote_settings: new Set([
    "id", "slot_minutes", "salespeople", "workday_start", "workday_end", "updated_at"
  ])
};

const json = (statusCode, body) => ({
  statusCode,
  headers: {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
    "x-content-type-options": "nosniff"
  },
  body: JSON.stringify(body)
});

const cleanRecord = (table, value) => {
  const allowed = TABLES[table];
  const source = value && typeof value === "object" && !Array.isArray(value) ? value : {};
  return Object.fromEntries(Object.entries(source).filter(([key]) => allowed.has(key)));
};

const safeColumns = (table, columns) => {
  if (!columns || columns === "*") return "*";
  const allowed = TABLES[table];
  const requested = String(columns).split(",").map((x) => x.trim()).filter(Boolean);
  const safe = requested.filter((column) => allowed.has(column));
  return safe.length ? safe.join(",") : "*";
};

export const handler = async (event) => {
  if (event.httpMethod !== "POST") return json(405, { error: "Method not allowed" });

  const supabaseUrl = process.env.SUPABASE_URL;
  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!supabaseUrl || !serviceKey) return json(503, { error: "Schedule service is not configured" });

  let body;
  try {
    body = JSON.parse(event.body || "{}");
  } catch {
    return json(400, { error: "Invalid request" });
  }

  const table = body.table;
  const operation = body.operation;
  if (!TABLES[table]) return json(400, { error: "Unsupported schedule resource" });
  if (!["select", "insert", "update", "delete", "upsert"].includes(operation)) {
    return json(400, { error: "Unsupported schedule operation" });
  }

  const url = new URL(`/rest/v1/${table}`, supabaseUrl);
  const filters = body.filters && typeof body.filters === "object" ? body.filters : {};
  for (const [column, value] of Object.entries(filters)) {
    if (!TABLES[table].has(column)) return json(400, { error: "Unsupported schedule filter" });
    url.searchParams.set(column, `eq.${value}`);
  }

  const headers = {
    apikey: serviceKey,
    authorization: `Bearer ${serviceKey}`,
    "content-type": "application/json"
  };
  let method = "GET";
  let requestBody;

  if (operation === "select") {
    url.searchParams.set("select", safeColumns(table, body.columns));
    const order = Array.isArray(body.order) ? body.order : [];
    const safeOrder = order
      .filter((item) => item && TABLES[table].has(item.column))
      .map((item) => `${item.column}.${item.ascending === false ? "desc" : "asc"}`);
    if (safeOrder.length) url.searchParams.set("order", safeOrder.join(","));
  } else if (operation === "delete") {
    if (!Object.keys(filters).length) return json(400, { error: "A delete filter is required" });
    method = "DELETE";
    headers.prefer = "return=representation";
  } else {
    const values = Array.isArray(body.values)
      ? body.values.map((value) => cleanRecord(table, value))
      : cleanRecord(table, body.values);
    if (Array.isArray(values) ? !values.length : !Object.keys(values).length) {
      return json(400, { error: "Schedule values are required" });
    }
    method = operation === "update" ? "PATCH" : "POST";
    if (operation === "update" && !Object.keys(filters).length) {
      return json(400, { error: "An update filter is required" });
    }
    if (operation === "upsert") {
      url.searchParams.set("on_conflict", table === "quote_settings" ? "id" : "id");
      headers.prefer = "resolution=merge-duplicates,return=representation";
    } else {
      headers.prefer = "return=representation";
    }
    requestBody = JSON.stringify(values);
  }

  try {
    const response = await fetch(url, { method, headers, body: requestBody });
    const text = await response.text();
    const data = text ? JSON.parse(text) : null;
    if (!response.ok) return json(response.status, { error: data?.message || data?.error || "Schedule request failed" });
    return json(200, { data });
  } catch (error) {
    console.error("Schedule API error", error);
    return json(502, { error: "The schedule database could not be reached" });
  }
};

