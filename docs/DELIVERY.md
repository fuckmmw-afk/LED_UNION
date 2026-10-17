# IPA delivery

The public download URL is
`https://fuckmmw.space/downloads/led-control/latest.ipa`. A deployment job must:

1. upload the new IPA to `/var/www/ipa/led-control/.latest.ipa.tmp`;
2. compute SHA-256 and keep the previous successful version;
3. atomically `mv` the temporary file to `latest.ipa`;
4. run `nginx -t`, then reload nginx only when the test passes;
5. run `curl -I` and a full download, then compare SHA-256.

Nginx serves `application/octet-stream` with `Content-Disposition: attachment`.
The reference location is [`nginx-led-control.conf`](nginx-led-control.conf).
Deployment credentials stay in GitHub/VPS secret storage and never appear in the
URL or in build logs. The `deploy` job in `.github/workflows/ios-unsigned.yml`
is protected by the `led-ipa-production` environment and runs only from
`workflow_dispatch` on `main`. It expects `VPS_HOST`, `VPS_USER`,
`VPS_SSH_PRIVATE_KEY` and `VPS_KNOWN_HOSTS` environment secrets, keeping
pull requests and ordinary pushes away from production.
