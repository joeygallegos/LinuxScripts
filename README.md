# Linux Scripts
Scripts that I use on my Linux servers for backup/deployment

## How to download
## How to configure

## How to run manually

```shell
sudo bash /home/backup_mysql.sh >> /home/backup.log
sudo bash /home/monitor_apache.sh >> /home/backup.log
```

# Required permissions for DB backup user
```sql
GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES
ON *.* TO 'backup_user'@'<host>';
```
