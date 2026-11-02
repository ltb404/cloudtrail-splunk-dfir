# cloudtrail-to-splunk

Scripts and configuration to bulk-load exported AWS CloudTrail logs into **Splunk Enterprise**.

## The problem

CloudTrail exports arrive as many `.tar.gz` / `.json.gz` files spread across `region/year/month/day` folders. Each file wraps all of its events in a single `{"Records":[ ... ]}` object. Indexed as-is, Splunk treats each file as one giant event, so searches, field extraction and timestamps break.

## The solution

1. **Flatten**: extract the archives and convert every file to newline-delimited JSON (one event per line).
2. **Configure**: apply the `aws:cloudtrail` sourcetype in `props.conf` so events get the correct timestamp and fields.
3. **Load**: ingest the flattened files with Splunk's one-shot input, in batches that respect your license quota.

## Repository layout

```
.
├── README.md
├── scripts/
│   ├── flatten.sh      # extracts archives and flattens files to NDJSON
│   └── oneshot.sh      # loads the flattened files into Splunk
└── splunk/
    └── props.conf      # aws:cloudtrail sourcetype settings
```

## Prerequisites

- Linux host with `bash`, `find`, `xargs`, `tar`, `zcat`
- [`jq`](https://jqlang.github.io/jq/) (check with `command -v jq`)
- Splunk Enterprise with admin access, installed on the same host
- Free disk space roughly equal to the **uncompressed** size of your logs

Install `jq` if missing:

```bash
sudo apt-get install -y jq    # Debian/Ubuntu
sudo yum install -y jq        # RHEL/CentOS/Amazon Linux
```

## Usage

### 1. Prepare Splunk

Create the index:

```bash
$SPLUNK_HOME/bin/splunk add index aws_cloudtrail
```

Copy `splunk/props.conf` to `$SPLUNK_HOME/etc/system/local/` (or into a custom app's `local/` folder), then restart Splunk:

```bash
$SPLUNK_HOME/bin/splunk restart
```

Make sure the index's retention (`frozenTimePeriodInSecs`) is longer than the age of your data, otherwise events may expire right after indexing.

### 2. Flatten the logs

```bash
./scripts/flatten.sh <source_dir> <dest_dir> [parallel_jobs]
```

Example:

```bash
./scripts/flatten.sh /raw /data/cloudtrail_flat 4
```

| Argument | Description |
|---|---|
| `source_dir` | Folder containing the exported `.tar.gz`, `.json.gz` or `.json` files |
| `dest_dir` | Output folder for the flattened `.ndjson` files (folder structure is preserved) |
| `parallel_jobs` | Optional. Number of parallel workers (default `4`) |

What it does:

- Extracts `.tar.gz` archives, then flattens all CloudTrail files
- Skips macOS junk files (`._*`, `.DS_Store`)
- Removes outputs that contain no events
- Lists any failed files in `<dest_dir>_failed.log` and exits with code `2`
- Cleans up its temporary extraction folder when everything succeeds

### 3. Check the volume against your license

Splunk counts **uncompressed** bytes indexed per day. Check the flattened size first:

```bash
du -sh /data/cloudtrail_flat
```

If it is larger than your daily quota, load in several runs using the size limit in the next step.

### 4. Load into Splunk

```bash
./scripts/oneshot.sh <ndjson_dir> [max_gb_per_run]
```

Examples:

```bash
./scripts/oneshot.sh /data/cloudtrail_flat        # load everything
./scripts/oneshot.sh /data/cloudtrail_flat 40     # stop after ~40 GB, continue tomorrow
```

| Setting | Description |
|---|---|
| `ndjson_dir` | Folder with the flattened `.ndjson` files |
| `max_gb_per_run` | Optional. Stop after roughly this many GB so you stay under your daily quota |

Environment variables (all optional):

| Variable | Default | Purpose |
|---|---|---|
| `SPLUNK_HOME` | `/opt/splunk` | Splunk install path |
| `INDEX` | `aws_cloudtrail` | Target index |
| `SOURCETYPE` | `aws:cloudtrail` | Sourcetype |
| `DONE_LOG` | `./oneshot_done.log` | Tracks loaded files so re-runs skip them |
| `SPLUNK_AUTH` | none | `user:password`, if you are not logged in via `splunk login` |

Re-running the script is safe: files already listed in the done log are skipped.

### 5. Verify

Run these searches in Splunk:

```spl
index=aws_cloudtrail | stats count by awsRegion
index=aws_cloudtrail | timechart span=1d count
index=aws_cloudtrail | stats min(_time) as first max(_time) as last | convert ctime(first) ctime(last)
```

Confirm the date range matches your export and that fields such as `eventName`, `userIdentity.arn` and `sourceIPAddress` are extracted.

To monitor license usage while loading:

```spl
index=_internal source=*license_usage.log type=Usage earliest=-1d
| stats sum(b) as bytes
| eval GB=round(bytes/1024/1024/1024,2)
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `gzip: ._...json.gz: not in gzip format` | macOS metadata file (about 160 bytes) | `flatten.sh` skips these; you can also delete them with `find . -name '._*' -delete` |
| `jq: command not found` | `jq` is not installed | Install `jq`, delete empty outputs (`find <dest_dir> -type f -empty -delete`), rerun |
| Failures listed in `<dest_dir>_failed.log` | Truncated or corrupt archive | Test with `gzip -t <file>` or `tar -tzf <file>` and re-export it |
| Events show the wrong time | Sourcetype not applied | Check `props.conf` is installed, Splunk was restarted, and the sourcetype is `aws:cloudtrail` |
| Whole file appears as one event | Files were not flattened | Run `flatten.sh` first and check with `head -n 2` on an output file |
| Data disappears after indexing | Index retention too short | Increase `frozenTimePeriodInSecs` for the index |
| `oneshot.sh` asks for credentials or fails to authenticate | Not logged in to Splunk CLI | Run `splunk login` or set `SPLUNK_AUTH` |

## Notes

- `oneshot.sh` uses Linux `stat -c`, so it is not compatible with macOS.
- If the scripts are not executable after cloning, run `chmod +x scripts/*.sh` or call them with `bash scripts/<name>.sh`.
- Keep your original export as a backup; the scripts never modify the source folder.
- Optional: the [Splunk Add-on for AWS](https://splunkbase.splunk.com/app/1876) adds CIM field mappings for `aws:cloudtrail`. Its own inputs read from S3/SQS, so for local exports keep using this workflow.

## Contributing

Issues and pull requests are welcome. Please test changes on a small sample before submitting.

## Disclaimer

Not affiliated with or endorsed by Splunk or Amazon Web Services. Test on a small subset or a throwaway index before loading production data.
