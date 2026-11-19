#!/usr/bin/env bash

MySQL2MariaDB_Manual_Migration_Guide()
{
    cat <<'EOF'
Automatic MySQL-to-MariaDB migration is DISABLED in this release.
Cross-database migration, restore and rollback have not passed real-server acceptance.
This safety gate is not a completed or supported automatic migration implementation.
No credentials are requested and no service, binary, configuration or data is changed.
There is no force/unsafe/checksum override for this restriction.

Do not use the fresh MariaDB installer to overwrite a MySQL installation or datadir.
A DBA must prepare a separate migration plan for the exact source/target versions:
1. Review SQL, authentication, grants, plugins, storage engines and application
   compatibility. Verify trusted source archives and fixed SHA256 checksums.
2. Build and validate the candidate in a separate prefix/host BEFORE downtime.
   Keep the original MySQL binaries, configuration and data untouched.
3. Quiesce application writers, scheduled events, replication and external jobs.
   Take protected, non-overwriting backups including routines, events, triggers,
   grants and all data. Verify every backup command. Prepare a consistent physical
   rollback backup using supported backup tooling, or a verified cold snapshot
   after stopping only the source database in the maintenance window. Include
   matching binaries/configuration/keys; do not copy a running datadir as a backup.
4. Restore into isolated disposable instances and test data, schema, grants,
   routines, events, triggers and application queries. Rehearse recovery back to
   the ORIGINAL MySQL version. A dump file or successful build is not acceptance.
5. Only after that evidence and an approved maintenance window, stop ONLY the
   relevant database service, never the entire LNMP stack. Keep writers blocked
   through validation and retain the original installation and rollback snapshot.
   Never start MySQL on a datadir that MariaDB has modified. Once writes resume,
   rollback needs a separately tested data recovery/PITR plan.

No automatic migration is performed by this entry point. Existing services stay as-is.
EOF
}

Backup_MySQL2()
{
    # Do not expose the old stop-and-move helper to direct callers either.
    MySQL2MariaDB_Manual_Migration_Guide
    return 1
}

Upgrade_MySQL2MariaDB()
{
    MySQL2MariaDB_Manual_Migration_Guide
    return 1
}
