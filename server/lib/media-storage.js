import fs from "node:fs";
import { HeadObjectCommand, GetObjectCommand, PutObjectCommand, S3Client } from "@aws-sdk/client-s3";

let client;

export function usesAwsMedia() {
  return String(process.env.OUNJE_MEDIA_STORAGE_PROVIDER ?? "").trim().toLowerCase() === "s3";
}

function configuration() {
  const region = String(process.env.AWS_REGION ?? "us-east-2").trim();
  const publicBucket = String(process.env.OUNJE_MEDIA_PUBLIC_BUCKET ?? "").trim();
  const privateBucket = String(process.env.OUNJE_MEDIA_PRIVATE_BUCKET ?? "").trim();
  const publicBaseURL = String(process.env.OUNJE_MEDIA_PUBLIC_BASE_URL ?? "").trim().replace(/\/+$/, "");
  if (!region || !publicBucket || !privateBucket || !/^https:\/\//.test(publicBaseURL)) {
    throw new Error("S3 media requires AWS_REGION, OUNJE_MEDIA_PUBLIC_BUCKET, OUNJE_MEDIA_PRIVATE_BUCKET, and an HTTPS OUNJE_MEDIA_PUBLIC_BASE_URL");
  }
  return { region, publicBucket, privateBucket, publicBaseURL };
}

function s3() {
  if (!client) client = new S3Client({ region: configuration().region, maxAttempts: 3 });
  return client;
}

function objectKey(logicalBucket, objectPath) {
  const bucket = String(logicalBucket ?? "").trim();
  const path = String(objectPath ?? "").trim().replace(/^\/+/, "");
  if (!/^[a-z0-9_-]+$/.test(bucket) || !path || path.split("/").some((part) => !part || part === "." || part === "..")) {
    throw new Error("Invalid media object path");
  }
  return `${bucket}/${path}`;
}

export function awsMediaReference(logicalBucket) {
  return `s3:${logicalBucket}`;
}

export function isAwsMediaReference(value) {
  return String(value ?? "").startsWith("s3:");
}

export function publicAwsMediaURL(logicalBucket, objectPath) {
  const { publicBaseURL } = configuration();
  const key = objectKey(logicalBucket, objectPath);
  return `${publicBaseURL}/${key.split("/").map(encodeURIComponent).join("/")}`;
}

export function isPublicAwsMediaURL(value, logicalBucket) {
  if (!usesAwsMedia()) return false;
  try {
    return String(value ?? "").startsWith(`${configuration().publicBaseURL}/${encodeURIComponent(logicalBucket)}/`);
  } catch {
    return false;
  }
}

export async function awsMediaExists(logicalBucket, objectPath) {
  return Boolean(await headAwsMedia(logicalBucket, objectPath));
}

export async function headAwsMedia(logicalBucket, objectPath) {
  const { publicBucket } = configuration();
  try {
    const result = await s3().send(new HeadObjectCommand({ Bucket: publicBucket, Key: objectKey(logicalBucket, objectPath) }));
    return { bytes: result.ContentLength, contentType: result.ContentType, etag: result.ETag };
  } catch (error) {
    if (error?.$metadata?.httpStatusCode === 404 || error?.name === "NotFound") return null;
    throw error;
  }
}

export async function uploadAwsMedia({ logicalBucket, objectPath, data, filePath, contentType, privateObject = false, cacheControl }) {
  const { publicBucket, privateBucket } = configuration();
  if (Boolean(data) === Boolean(filePath)) throw new Error("Provide exactly one media body source");
  const body = filePath ? fs.createReadStream(filePath) : data;
  const command = new PutObjectCommand({
    Bucket: privateObject ? privateBucket : publicBucket,
    Key: objectKey(logicalBucket, objectPath),
    Body: body,
    ContentLength: filePath ? fs.statSync(filePath).size : data.length,
    ContentType: contentType,
    CacheControl: cacheControl ?? (privateObject ? "private, max-age=0" : "public, max-age=31536000, immutable"),
    ServerSideEncryption: "AES256",
  });
  try {
    await s3().send(command);
  } finally {
    if (filePath) body.destroy();
  }
  return privateObject ? awsMediaReference(logicalBucket) : publicAwsMediaURL(logicalBucket, objectPath);
}

export async function fetchPrivateAwsMedia(reference, objectPath, maxBytes = 10 * 1024 * 1024) {
  if (!isAwsMediaReference(reference)) throw new Error("Not an S3 media reference");
  const { privateBucket } = configuration();
  const result = await s3().send(new GetObjectCommand({
    Bucket: privateBucket,
    Key: objectKey(reference.slice(3), objectPath),
  }));
  if (result.ContentLength > maxBytes) {
    result.Body?.destroy?.();
    throw new Error("Private media object exceeds download limit");
  }
  const chunks = [];
  let size = 0;
  try {
    for await (const chunk of result.Body) {
      size += chunk.length;
      if (size > maxBytes) throw new Error("Private media object exceeds download limit");
      chunks.push(chunk);
    }
  } finally {
    result.Body?.destroy?.();
  }
  return { buffer: Buffer.concat(chunks), mime_type: result.ContentType ?? null };
}
