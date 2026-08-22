# Local build guide

## 1. Build host

Recommended host: Ubuntu 24.04 x86_64. Use an ordinary non-root user with sudo. Give the workspace generous free disk space; Qualcomm targets plus external packages generate large build trees.

Install dependencies:

```bash
sudo apt update
sudo apt install -y \
  build-essential clang flex bison g++ gawk gcc-multilib gettext git \
  libncurses-dev libssl-dev python3 python3-setuptools python3-pyelftools \
  rsync swig unzip zlib1g-dev file wget curl libelf-dev ecj fastjar xsltproc \
  qemu-utils ccache
```

## 2. Get this build project

Clone your own GitHub repository after you have pushed these files, then enter the project directory.

```bash
git clone https://github.com/YOUR_GITHUB_USER/jdcloud-arthur-64g-build.git
cd jdcloud-arthur-64g-build
```

## 3. Run the automated build

```bash
./scripts/build.sh main
```

The script performs the important learning steps in the same order you would do manually:

1. Clone `VIKINGYFY/immortalwrt` `main`.
2. Update and install standard feeds.
3. Pull the external plug-ins requested for this firmware.
4. Copy the JDCloud RE-SS-01 seed config to `.config`.
5. Run `make defconfig` so dependencies are resolved.
6. Verify all requested LuCI package symbols remain enabled.
7. Run `make download`.
8. Compile the firmware.
9. Collect JDCloud RE-SS-01 images and hashes into `output/firmware/`.

## 4. Learn the manual equivalent

If you want to understand every command instead of calling the wrapper:

```bash
git clone -b main https://github.com/VIKINGYFY/immortalwrt.git
cd immortalwrt
./scripts/feeds update -a
./scripts/feeds install -a
```

From the build-project directory, add external packages:

```bash
../scripts/add-custom-packages.sh "$PWD"
```

Apply the seed config and resolve dependencies:

```bash
cp ../config/arthur.config .config
make defconfig
../scripts/check-config.sh .config
```

Optional interactive inspection:

```bash
make menuconfig
```

The target must remain:

```text
Target System: Qualcomm Atheros IPQ60xx/IPQ807x/IPQ50xx
Subtarget: IPQ60xx
Target Profile: JDCloud RE-SS-01
```

Download source archives:

```bash
make download -j$(nproc)
find dl -type f -size -1024c -delete
```

Compile:

```bash
make -j$(nproc)
```

If the parallel build fails, use the verbose single-thread command to locate the real error:

```bash
make -j1 V=s
```

## 5. Output

Look under:

```text
bin/targets/qualcommax/ipq60xx/
```

The files containing `jdcloud_re-ss-01` are the target-specific images. Keep the generated hashes and `profiles.json` together with the firmware.

## 6. Important point about “64G”

The 64 GB Arthur is not a separate OpenWrt target. `RE-SS-01` is the hardware target; 64/128/256 GB are eMMC capacity variants. Do not invent a `64g` device profile or change the DTS only because the eMMC is 64 GB.
