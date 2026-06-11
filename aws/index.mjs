// BinderBooks sync API — runs as AWS Lambda "binderbooks-sync" (us-west-2)
// behind API Gateway HTTP API "j18dixq7ei" ($default route, payload v2).
// The whole ledger is one JSON blob in the "binderbooks" DynamoDB table;
// writes are conditional on updatedAt so an out-of-date device gets a 409
// instead of clobbering newer data.
// (A Lambda function URL was the first attempt, but public function URLs
// return 403 on this account regardless of resource policy.)
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, GetCommand, PutCommand } from "@aws-sdk/lib-dynamodb";
import { timingSafeEqual } from "node:crypto";

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const TABLE = process.env.TABLE_NAME;
const ID = "ledger";
// DynamoDB items max out at 400 KB; leave headroom for attribute overhead
const MAX_BYTES = 350_000;

const res = (code, body) => ({
  statusCode: code,
  headers: { "content-type": "application/json" },
  body: JSON.stringify(body),
});

const authed = (event) => {
  const got = Buffer.from(String(event.headers?.["x-sync-token"] || ""));
  const want = Buffer.from(String(process.env.SYNC_TOKEN));
  return got.length === want.length && timingSafeEqual(got, want);
};

export const handler = async (event) => {
  const method = event.requestContext?.http?.method;
  // CORS preflight must get a 2xx; API Gateway injects the CORS headers
  if (method === "OPTIONS") return { statusCode: 204 };
  if (!authed(event)) return res(401, { error: "unauthorized" });

  if (method === "GET") {
    const r = await ddb.send(new GetCommand({ TableName: TABLE, Key: { id: ID } }));
    if (!r.Item) return res(404, { error: "empty" });
    // conditional pull: client sends the stamp it has; identical -> tiny 204 instead of the blob
    if (Number(event.queryStringParameters?.since) === r.Item.updatedAt) return { statusCode: 204 };
    return res(200, { updatedAt: r.Item.updatedAt, data: r.Item.data });
  }

  if (method === "PUT") {
    let body;
    try { body = JSON.parse(event.body || ""); } catch { return res(400, { error: "bad json" }); }
    const { updatedAt, data } = body;
    if (typeof updatedAt !== "number" || typeof data !== "string" || data.length > MAX_BYTES)
      return res(400, { error: "bad payload" });
    try {
      await ddb.send(new PutCommand({
        TableName: TABLE,
        Item: { id: ID, updatedAt, data },
        ConditionExpression: "attribute_not_exists(id) OR updatedAt <= :ts",
        ExpressionAttributeValues: { ":ts": updatedAt },
      }));
    } catch (e) {
      if (e.name === "ConditionalCheckFailedException") return res(409, { error: "stale" });
      throw e;
    }
    return res(200, { ok: true });
  }

  return res(405, { error: "method not allowed" });
};
