# GitHub workflow

## Repository layout

Keep only build orchestration in your repository. Do not vendor the entire ImmortalWrt source tree.

```text
.github/workflows/build.yml
config/arthur.config
docs/
scripts/
README.md
```

## First push

Create an empty GitHub repository, for example `jdcloud-arthur-64g-build`, then run:

```bash
git init
git add .
git commit -m "init: JDCloud Arthur 64G firmware build"
git branch -M main
git remote add origin https://github.com/YOUR_GITHUB_USER/jdcloud-arthur-64g-build.git
git push -u origin main
```

## Actions build

Open the repository's Actions tab, choose `Build JDCloud Arthur 64G`, then run the workflow. The workflow accepts the upstream source ref, which defaults to `main`.

Build results are uploaded as a GitHub Actions artifact. When you push a tag beginning with `v`, the same workflow also creates a GitHub Release and attaches the firmware files.

Example release flow:

```bash
git tag v0.1.0
git push origin v0.1.0
```

## Updating later

The build repository should record configuration and source choices. Each build also saves `SOURCES.txt`, which records the exact upstream ImmortalWrt commit and custom package commit SHAs used by that run.
