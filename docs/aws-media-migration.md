# AWS recipe media

The `ounje-media` CloudFormation stack in `us-east-2` owns two private S3 buckets
and a CloudFront distribution. Public recipe videos and images are stored in the
public bucket under their original logical bucket names, for example
`recipe-videos/example.mp4`. Private photo imports use the separate private
bucket. S3 public access stays blocked; CloudFront is the public read path.

Set `OUNJE_MEDIA_STORAGE_PROVIDER=s3` on both the API and ingestion worker,
along with `AWS_REGION`, `OUNJE_MEDIA_PUBLIC_BUCKET`,
`OUNJE_MEDIA_PRIVATE_BUCKET`, and `OUNJE_MEDIA_PUBLIC_BASE_URL`. Both services
need AWS credentials limited to these buckets. The reviewed policy is in
`infra/render-media-s3-policy.json`; it allows object reads and writes only
inside the two media buckets. Keep credentials in the hosting service's secret
settings, never in this repository.

The recovery scripts in `server/scripts/` rebuild videos from recorded source
URLs and images from recorded source URLs, recovered video frames, or recipe
page images. Their checkpoint files are local and ignored by Git. A rebuilt
file can differ from its original Supabase bytes. The scripts verify S3 and
CloudFront playback before changing database URLs. Files without an accessible
source retain their Supabase URLs.

When Supabase Storage access is restored, `plan-recovered` shows how many
rebuilt, switched, unreferenced originals can be removed immediately.
`delete-recovered` removes only that verified subset through the Supabase
Storage API. It retains files whose URLs are hardcoded in shipped iOS builds.
The remaining originals can then be handled with the `plan`, `copy`, `switch`,
and `delete` phases. `copy` fetches the exact original bytes and overwrites
rebuilt copies; the full `switch` and `delete` phases require every remaining
public object to pass verification. Do not delete rows from `storage.objects`
directly: that does not remove the underlying file.
