# cloudtrail-to-splunk

Scripts and configuration to bulk-load exported AWS CloudTrail logs (`.json.gz`) into **Splunk Enterprise** for analysis.

CloudTrail log files wrap all events in a single `{"Records":[ ... ]}` object. Splunk would index each file as one giant event, so this package first flattens the files into newline-delimited JSON (one event per line), then ingests them with correct timestamp and field extraction settings.

## Features

- Flattens CloudTrail `.json.gz` files to NDJSON, preserving the `region/year/month/day` directory structure
- Parallel processing with `xargs -P`
- Skips macOS metadata junk (`._*`, `.DS_Store`, `__MACOSX`)
- Fails loudly: failed files are reported and partial output is removed
- Ready-to-use `props.conf`, `indexes.conf` and `inputs.conf` examples
- Guidance for staying within Splunk daily license limits
- Verification searches and troubleshooting for common errors

## Prerequisites

| Requirement | Notes |
|---|---|
| Linux host with shell access | Where the raw files and Splunk (or a staging area) live |
| `bash`, `find`, `xargs`, `zcat` | Standard on most distributions |
| [`jq`](https://jqlang.github.io/jq/) | **Required.** Check with `command -v jq` |
| Splunk Enterprise with admin access | Needed to create an index and edit `.conf` files |
| Free disk space | About the uncompressed size of your data for the flattened staging copy |

Install `jq`:

```bash
# Debian/Ubuntu
sudo apt-get install -y jq
# RHEL/CentOS/Amazon Linux
sudo yum install -y jq
```

## Expected input layout

```
/raw/
└── <region>/
    └── <year>/<month>/<day>/
        └── <account>_CloudTrail_<region>_<timestamp>_<id>.json.gz
```

## Repository layout

```
.
├── README.md
├── scripts/
│   └── flatten.sh          # Flattens .json.gz to .ndjson
└── splunk/
    ├── props.conf          # aws:cloudtrail sourcetype
```

## Quick start

### 1. Clean the raw data (optional but recommended)

If the archive passed through macOS, remove AppleDouble files. They are about 160 bytes and cause `not in gzip format` errors.

```bash
cd /raw
find . -name '._*' -delete
find . \( -name '.DS_Store' -o -name '__MACOSX' \) -print
```

### 2. Estimate the uncompressed size

Splunk licensing counts uncompressed volume, and `.gz` ratios vary (typically 10-15x for CloudTrail).

```bash
cd /raw
find . -name '*.json.gz' ! -name '._*' -print0 \
  | xargs -0 zcat | wc -c | awk '{printf "%.1f GB\n", $1/1024/1024/1024}'
```

Compare the result with your daily ingest license quota.

### 3. Flatten the files

```bash
mkdir -p /data/cloudtrail_flat
cd /raw

flatten() {
  set -o pipefail
  f="$1"
  out="/data/cloudtrail_flat/${f#./}"
  out="${out%.json.gz}.ndjson"
  mkdir -p "$(dirname "$out")"
  zcat "$f" | jq -c '.Records[]' > "$out" || { echo "FAILED: $f" >&2; rm -f "$out"; }
}
export -f flatten

find . -type f -name '*.json.gz' ! -name '._*' -print0 \
  | xargs -0 -P 4 -I{} bash -c 'flatten "$@"' _ {}
```

Adjust `-P 4` to your CPU core count.

### 4. Verify the flattened output

```bash
# Source files vs. output files (counts should match, except genuinely empty files)
find /raw -type f -name '*.json.gz' ! -name '._*' | wc -l
find /data/cloudtrail_flat -type f -name '*.ndjson' -size +0 | wc -l

# Empty outputs
find /data/cloudtrail_flat -type f -empty | wc -l

# Each line should be one complete JSON event
head -n 2 "$(find /data/cloudtrail_flat -name '*.ndjson' -size +0 | head -1)"
```

A few empty outputs can be legitimate: CloudTrail occasionally writes files containing `"Records":[]`. A large number points to a problem.

### 5. Configure Splunk

Create an index for your data.

**`props.conf`**

```ini
[aws:cloudtrail]
SHOULD_LINEMERGE = false
LINE_BREAKER = ([\r\n]+)
TIME_PREFIX = "eventTime":\s*"
TIME_FORMAT = %Y-%m-%dT%H:%M:%SZ
MAX_TIMESTAMP_LOOKAHEAD = 25
TZ = UTC
KV_MODE = json
TRUNCATE = 0
```

Place these in `$SPLUNK_HOME/etc/system/local/` or in a custom app, then restart Splunk.

### 6. Ingest

```bash
find /data/cloudtrail_flat -type f -name '*.ndjson' | while read -r f; do
  $SPLUNK_HOME/bin/splunk add oneshot "$f" \
    -index aws_cloudtrail -sourcetype aws:cloudtrail
done
```

## Licensing

Splunk counts the uncompressed bytes indexed per day. A one-day load larger than your quota causes a license warning, and repeated warnings can restrict search depending on your license type.

Ways to stay under the limit:

- Load one region (or one week or month) per day by staging subsets of files into the ingest directory
- Load part of the data before midnight and the rest after it (the license day resets at midnight in the license manager's time zone)

Monitor today's usage:

```spl
index=_internal source=*license_usage.log type=Usage earliest=-1d
| stats sum(b) as bytes
| eval GB=round(bytes/1024/1024/1024,2)
```

## Verifying the load in Splunk

```spl
index=aws_cloudtrail | stats count by awsRegion
index=aws_cloudtrail | timechart span=1d count
index=aws_cloudtrail | stats min(_time) as first max(_time) as last | convert ctime(first) ctime(last)
```

Check that the date range matches your export and that fields such as `eventName`, `userIdentity.arn` and `sourceIPAddress` are extracted.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `gzip: ./._...json.gz: not in gzip format` | macOS AppleDouble metadata file (about 160 bytes) | Delete `._*` files or exclude them with `! -name '._*'` |
| `jq: command not found` | `jq` is not installed | Install `jq` (see [Prerequisites](#prerequisites)), delete empty outputs with `find /data/cloudtrail_flat -type f -empty -delete`, then rerun |
| Events appear at the wrong time | Timestamp taken from the wrong field | Confirm `TIME_PREFIX` in `props.conf` and that the sourcetype is `aws:cloudtrail` |
| Events cut off | Default line truncation | Set `TRUNCATE = 0` |
| Whole file shows as one event | Files not flattened, or `LINE_BREAKER` missing | Flatten first and check `head -n 2` of the output |
| Data disappears shortly after indexing | Index retention shorter than the data's age | Increase `frozenTimePeriodInSecs` |
| `FAILED: <file>` for a real file | Truncated or corrupt archive | Test with `gzip -t <file>` and re-export that file |

## Optional: Splunk Add-on for AWS

The [Splunk Add-on for AWS](https://splunkbase.splunk.com/app/1876) provides CIM field mappings and knowledge objects for `aws:cloudtrail`, which is useful for Enterprise Security or the AWS app. Its inputs read from S3/SQS rather than local files, so for local exports keep using the flattening workflow above and install the add-on only for its knowledge objects.

## Contributing

Issues and pull requests are welcome. Please test changes against a small sample before submitting.

## Disclaimer

Not affiliated with or endorsed by Splunk or Amazon Web Services. Test on a small subset or a throwaway index before loading production data.
