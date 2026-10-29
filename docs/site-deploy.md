# Deploying frog.toys to Cloudflare Pages

This document describes the one-time setup steps to deploy the frog website to Cloudflare Pages.

## One-time setup in Cloudflare

1. **Create the Pages project**
   - Go to [Cloudflare Dashboard](https://dash.cloudflare.com/)
   - Navigate to **Workers & Pages** → **Pages** → **Create application**
   - Select **Direct Upload**
   - Name the project: `frog-site`
   - Click **Create project**

2. **Add custom domains**
   - In the Pages project, go to **Custom domains**
   - Add `frog.toys`
   - Add `www.frog.toys`
   - Cloudflare will automatically create the DNS records for you

3. **Set up GitHub repository secrets**
   - Go to your GitHub repository: `ecto/frog`
   - Navigate to **Settings** → **Secrets and variables** → **Actions**
   - Click **New repository secret**
   - Add `CLOUDFLARE_API_TOKEN` with your Cloudflare API token
   - Add `CLOUDFLARE_ACCOUNT_ID` with your Cloudflare Account ID

## API token and Account ID

To get your Cloudflare API token:
1. Go to [Cloudflare Tokens](https://dash.cloudflare.com/profile/api-tokens)
2. Create a token with **Edit** permissions for **Cloudflare Pages**
3. Copy the token value

To get your Account ID:
1. Go to [Cloudflare Dashboard](https://dash.cloudflare.com/)
2. Look at the right side of the URL bar - it's the long string after `dash.cloudflare.com/`
3. Or go to **Workers & Pages** → **Overview** → **Account ID**

## Deployment

After setup, pushes to `main` that touch `site/` will automatically deploy to Cloudflare Pages.

## Local development

Test locally with:
```bash
npx wrangler pages dev site
```

This starts a local dev server at `http://localhost:8788`.

## install.sh sync

`site/install.sh` is a synced copy of `scripts/install.sh` (the source of truth). When
`scripts/install.sh` changes, update `site/install.sh` in the same commit — the release
manager does this at tag time. CI can't easily diff them today: this is a known sync risk.
Check with:

```bash
diff scripts/install.sh site/install.sh
```

## Deprecated Vercel config

The `site/vercel.json` file is kept for now but is deprecated. It will be removed once the Cloudflare Pages deployment is stable.
