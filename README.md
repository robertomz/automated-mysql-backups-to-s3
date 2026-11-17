# Automated MySQL Backups to Amazon S3

A practical, production-oriented guide for automating MySQL backups from a Linux/EC2 server to Amazon S3 using:

- `mysqldump`
- Bash
- IAM Roles for EC2
- Amazon S3
- S3 Lifecycle rules
- `cron`
- Logging and validation
- Real restore testing

> A backup is not truly validated until it has been restored successfully.

## Architecture

```text
MySQL
  |
  v
mysqldump
  |
  v
Local temporary dump
  |
  +--> Validation + logs
  |
  v
Amazon S3
  |
  v
Lifecycle retention
```

AWS authentication is handled through an **IAM Role attached to the EC2 instance**. No AWS access key or secret key is stored in the backup script.

---

## 1. Requirements

Example environment:

- Ubuntu / Debian Linux server
- MySQL 5.7 or 8.x
- AWS CLI installed
- An S3 bucket
- An EC2 IAM Role with access to the backup bucket

Verify the required commands:

```bash
mysql --version
mysqldump --version
aws --version
```

---

## 2. Create an S3 bucket

Create a dedicated S3 bucket for database backups.

Example:

```text
my-company-database-backups
```

Recommended settings:

- Block Public Access: **Enabled**
- Versioning: optional
- Default encryption: **Enabled**
- Use separate prefixes for each database or environment

Example layout:

```text
s3://my-company-database-backups/
├── production/
│   ├── database_a/
│   └── database_b/
└── testing/
```

Do not expose the bucket publicly.

---

## 3. Create an IAM policy for the backup bucket

Use the example in [`iam/s3-backup-policy.json`](iam/s3-backup-policy.json).

Replace:

```text
YOUR_BACKUP_BUCKET
```

with your own bucket name.

The policy allows the instance to:

- list the backup bucket;
- upload backup objects;
- download backup objects for restore testing;
- delete objects if required by your workflow.

For stricter environments, reduce permissions further and restrict access to a specific prefix.

---

## 4. Create and attach an IAM Role to EC2

Create an IAM Role with:

```text
Trusted entity: AWS service
Use case: EC2
```

Attach the policy created in the previous step and attach the role to the EC2 instance that executes the backups.

Then verify from the server:

```bash
aws sts get-caller-identity
```

and:

```bash
aws s3 ls s3://YOUR_BACKUP_BUCKET/
```

If these commands work without configuring an AWS access key on the server, the IAM Role is working correctly.

---

## 5. Store MySQL credentials outside the script

Never hardcode the MySQL password inside the backup script.

Create a credentials file:

```bash
sudo mkdir -p /etc/mysql-backup
sudo nano /etc/mysql-backup/mysql-backup.cnf
```

Use [`examples/mysql-backup.cnf.example`](examples/mysql-backup.cnf.example) as a template:

```ini
[client]
user=backup_user
password=CHANGE_ME
port=3306
```

Protect it:

```bash
sudo chmod 600 /etc/mysql-backup/mysql-backup.cnf
```

If the backup process runs as another Linux user, ensure only that user can read the file.

---

## 6. Create the backup script

Copy [`scripts/backup_mysql_to_s3.sh`](scripts/backup_mysql_to_s3.sh) to the server:

```bash
sudo mkdir -p /opt/mysql-backup
sudo cp scripts/backup_mysql_to_s3.sh /opt/mysql-backup/
sudo chmod +x /opt/mysql-backup/backup_mysql_to_s3.sh
```

Edit these variables in the script:

```bash
DB_HOST="127.0.0.1"
DB_NAME="example_database"
MYSQL_CNF="/etc/mysql-backup/mysql-backup.cnf"
S3_BUCKET="YOUR_BACKUP_BUCKET"
S3_PREFIX="production/example_database"
```

The script performs this sequence:

```text
1. Generate dump
2. Record mysqldump output in a log
3. Validate that the dump is not empty
4. Upload the dump to S3
5. Verify the S3 upload command succeeded
6. Remove the temporary local dump
7. Return an appropriate exit code
```

Run it manually before scheduling it:

```bash
sudo /opt/mysql-backup/backup_mysql_to_s3.sh
```

Check the log:

```bash
tail -100 /var/log/mysql-backup/backup.log
```

Then confirm the object exists in S3:

```bash
aws s3 ls s3://YOUR_BACKUP_BUCKET/production/example_database/
```

---

## 7. About `mysqldump --force`

The default example does **not** enable `--force` automatically.

Some databases contain invalid views or other objects that cause `mysqldump` to return a non-zero exit code even though a large portion of the dump can still be generated.

In that specific situation, you can add:

```bash
--force
```

to the `mysqldump` command.

If you use `--force`:

1. review the log;
2. confirm the dump is not empty;
3. identify the objects that failed;
4. perform a real restore test.

Do not treat `--force` as a substitute for monitoring errors.

---

## 8. Configure S3 Lifecycle retention

Backups should not grow forever unless long-term retention is a requirement.

The example file [`examples/lifecycle.json`](examples/lifecycle.json) expires backup objects after **3 days** and aborts incomplete multipart uploads after **1 day**.

Apply it with:

```bash
aws s3api put-bucket-lifecycle-configuration \
  --bucket YOUR_BACKUP_BUCKET \
  --lifecycle-configuration file://examples/lifecycle.json
```

Check it:

```bash
aws s3api get-bucket-lifecycle-configuration \
  --bucket YOUR_BACKUP_BUCKET
```

Adjust retention according to your recovery requirements and compliance policies.

---

## 9. Schedule backups with cron

Edit the crontab of the user that will run the backup:

```bash
crontab -e
```

Example: run every day at 01:10 AM:

```cron
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
10 1 * * * /opt/mysql-backup/backup_mysql_to_s3.sh >> /var/log/mysql-backup/cron.log 2>&1
```

A sample is included in [`examples/crontab.example`](examples/crontab.example).

After the first scheduled execution, verify:

```bash
tail -100 /var/log/mysql-backup/cron.log
```

and confirm that a new S3 object was created.

---

## 10. Multiple databases

A simple approach is to keep one backup script per database and call them from a wrapper.

Example:

```bash
#!/bin/bash

set -u

/opt/mysql-backup/backup_database_a.sh
/opt/mysql-backup/backup_database_b.sh
/opt/mysql-backup/backup_database_c.sh
```

Alternatively, adapt the script to iterate over an explicit allowlist of databases.

Avoid blindly dumping every database if system databases or temporary schemas should not be included.

---

## 11. Test a real restore

This is the step that validates the backup strategy.

Use a non-production database/server for restore testing whenever possible.

List available backups:

```bash
aws s3 ls s3://YOUR_BACKUP_BUCKET/production/example_database/
```

Download a selected backup:

```bash
aws s3 cp \
  s3://YOUR_BACKUP_BUCKET/production/example_database/example_database_YYYYMMDD_HHMMSS.sql \
  /tmp/restore-test.sql
```

Create a test database:

```bash
mysql \
  --defaults-extra-file=/etc/mysql-backup/mysql-backup.cnf \
  -h 127.0.0.1 \
  -e 'CREATE DATABASE IF NOT EXISTS restore_test;'
```

Restore:

```bash
mysql \
  --defaults-extra-file=/etc/mysql-backup/mysql-backup.cnf \
  -h 127.0.0.1 \
  restore_test < /tmp/restore-test.sql
```

Then validate tables and representative data:

```bash
mysql \
  --defaults-extra-file=/etc/mysql-backup/mysql-backup.cnf \
  -h 127.0.0.1 \
  -e 'USE restore_test; SHOW TABLES;'
```

A reusable restore helper is included in [`scripts/restore_mysql_from_s3.sh`](scripts/restore_mysql_from_s3.sh).

---

## 12. Troubleshooting

### Dump file is empty

Check:

```bash
tail -100 /var/log/mysql-backup/backup.log
```

Common causes:

- invalid credentials;
- incorrect host;
- network or firewall issue;
- missing MySQL privileges;
- invalid defaults file path.

### `mysqldump` returns exit code 1

Review the log before assuming the entire dump failed.

Invalid views are a common cause in legacy databases. Fix the invalid object when possible. Use `--force` only when you understand and accept the consequence.

### AWS CLI returns `AccessDenied`

Check the IAM identity:

```bash
aws sts get-caller-identity
```

Then confirm:

- the EC2 IAM Role is attached;
- the IAM policy references the correct bucket;
- the bucket policy does not explicitly deny the action.

### Script works as root but fails in cron

Cron has a smaller environment than an interactive shell.

Use absolute paths and define `PATH` in the crontab.

Also verify that the cron user can read:

```text
/etc/mysql-backup/mysql-backup.cnf
```

and can write to the backup/log directories.

### Backup uploads correctly but restore fails

A successful S3 upload only proves that a file was stored. It does not prove that the SQL dump is logically complete or restorable.

Inspect the original dump log and perform periodic restore tests.

---

## Security checklist

- Use an EC2 IAM Role instead of AWS access keys on disk.
- Keep the S3 bucket private.
- Enable S3 encryption.
- Restrict the IAM policy to the required bucket/prefix.
- Store MySQL credentials outside scripts.
- Set the MySQL credentials file to mode `600`.
- Use a dedicated MySQL backup user with only the privileges it needs.
- Do not commit `.cnf` files containing passwords.
- Do not commit database dumps.
- Review backup logs regularly.
- Test restores periodically.

---

## Suggested production improvements

Depending on the environment, consider adding:

- CloudWatch alarms for failed backup jobs;
- SNS/email notifications;
- S3 Object Lock for immutable backups;
- cross-region or cross-account copies;
- longer retention tiers using S3 Glacier;
- encryption with a customer-managed KMS key;
- checksum validation;
- scheduled restore drills.

---

## Final verification checklist

Before considering the setup complete:

```text
[ ] IAM Role works without static AWS keys
[ ] mysqldump completes or known warnings are reviewed
[ ] dump file is not empty
[ ] S3 upload succeeds
[ ] lifecycle rule is enabled
[ ] cron executes successfully
[ ] logs are being generated
[ ] temporary local dump is removed
[ ] a real restore has been completed successfully
```

---

## License

MIT License. See [`LICENSE`](LICENSE).
