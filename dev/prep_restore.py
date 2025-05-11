#!/usr/bin/env python3
"""
prep_restore_full.py

This script processes a pg_dump --data-only backup file to make it suitable for
restoring into a target database whose schema might differ (for example, missing
some columns). It does the following:

1. It auto-detects the running Postgres container and target database:
   - If the container name contains "devcontainer", the target database is "wanderer_dev".
   - Otherwise, the target database is "postgres".

2. It rewrites each COPY header so that its column list is replaced with the list of
   columns that exist in the target database (as retrieved from information_schema.columns).

3. It processes the data rows in each COPY block so that if any row has extra fields
   (more than the expected number of columns), those extra fields are trimmed off.
   In particular, if a row has one extra field and that field is empty, it is removed.

Usage:
    ./prep_restore_full.py <input_backup.sql> <output_backup.sql>
"""

import sys
import re
import subprocess

def get_target_columns(full_table, container, db_user, db_name):
    """
    Given a full table name (possibly schema-qualified), return a list of column names
    from the target database using a proper string_agg query.
    """
    if '.' in full_table:
        schema, table = full_table.split('.', 1)
    else:
        schema = 'public'
        table = full_table

    # Build the SQL query.
    # The correct syntax places the ORDER BY inside the string_agg function.
    query = (
        "SELECT string_agg(quote_ident(column_name), ', ' ORDER BY ordinal_position) "
        "FROM information_schema.columns "
        "WHERE table_schema = '{schema}' AND table_name = '{table}';"
    ).format(schema=schema, table=table)

    cmd = [
        "docker", "exec", "-i", container,
        "psql", "-U", db_user, "-d", db_name, "-t", "-c", query
    ]
    try:
        result = subprocess.check_output(cmd, universal_newlines=True)
        result = result.strip()
        if result:
            # Split on comma and strip each column name.
            cols = [col.strip() for col in result.split(",")]
            return cols
        else:
            return []
    except subprocess.CalledProcessError as e:
        sys.stderr.write("Error running command: {}\n".format(" ".join(cmd)))
        sys.stderr.write(e.output)
        return []

def auto_detect_container(possible_containers):
    """Return the first container from the list that exists."""
    for c in possible_containers:
        try:
            subprocess.check_output(["docker", "inspect", c])
            return c
        except subprocess.CalledProcessError:
            continue
    return None

def main():
    if len(sys.argv) != 3:
        print("Usage: {} <input_backup.sql> <output_backup.sql>".format(sys.argv[0]))
        sys.exit(1)

    input_file = sys.argv[1]
    output_file = sys.argv[2]

    try:
        fin = open(input_file, "r")
    except IOError as e:
        sys.stderr.write("Error opening input file {}: {}\n".format(input_file, e))
        sys.exit(1)

    try:
        fout = open(output_file, "w")
    except IOError as e:
        sys.stderr.write("Error opening output file {}: {}\n".format(output_file, e))
        sys.exit(1)

    possible_containers = ["wanderer-wanderer_db-1", "wanderer_devcontainer-db-1"]
    container = auto_detect_container(possible_containers)
    if container is None:
        sys.stderr.write("Error: No known Postgres container found. Checked: {}\n".format(possible_containers))
        sys.exit(1)

    # Determine target database.
    if "devcontainer" in container:
        db_name = "wanderer_dev"
    else:
        db_name = "postgres"
    db_user = "postgres"

    print("Using database container: {}".format(container))
    print("Target database: {}".format(db_name))
    print("Processing backup file...")

    # Pattern to match a COPY header.
    # Example:
    #   COPY public.user_v1 (id, name, hash, ...) FROM stdin;
    copy_header_pattern = re.compile(r"^(COPY\s+)(\S+)(\s+)\(([^)]*)\)(\s+FROM\s+stdin;)", re.IGNORECASE)

    in_copy_block = False
    expected_col_count = 0
    current_table = None

    for line in fin:
        m = copy_header_pattern.match(line)
        if m:
            # We're at a COPY header.
            prefix = m.group(1)
            full_table = m.group(2)   # e.g., public.user_v1
            spacer = m.group(3)
            orig_cols = m.group(4)    # original column list (to be replaced)
            suffix = m.group(5)
            target_cols_list = get_target_columns(full_table, container, db_user, db_name)
            if target_cols_list:
                expected_col_count = len(target_cols_list)
                new_header = "{}{}{}({}){}".format(prefix, full_table, spacer, ", ".join(target_cols_list), suffix)
                fout.write(new_header + "\n")
                print("Rewrote COPY header for table {}: using {} columns.".format(full_table, expected_col_count))
                in_copy_block = True
                current_table = full_table
            else:
                fout.write(line)
                print("Warning: Could not get target columns for table {}. Leaving header unchanged.".format(full_table))
                in_copy_block = True
                current_table = full_table
                expected_col_count = None  # unknown
            continue

        if in_copy_block:
            # Inside a COPY block, data rows follow until the terminator "\." line.
            if line.strip() == "\\.":
                fout.write(line)
                print("Finished COPY block for table {}.".format(current_table))
                in_copy_block = False
                current_table = None
                expected_col_count = 0
            else:
                if expected_col_count is not None:
                    # Process the data row: split on tab.
                    row = line.rstrip("\n")
                    fields = row.split("\t")
                    # If there is one extra field that is empty, remove it.
                    if len(fields) == expected_col_count + 1 and fields[-1] == "":
                        fields = fields[:-1]
                    # If still too many fields, trim to expected count.
                    if len(fields) > expected_col_count:
                        fields = fields[:expected_col_count]
                    new_line = "\t".join(fields) + "\n"
                    fout.write(new_line)
                else:
                    fout.write(line)
            continue

        # Outside a COPY block, write the line unchanged.
        fout.write(line)

    fin.close()
    fout.close()
    print("Preprocessing complete. Output written to {}".format(output_file))

if __name__ == "__main__":
    main()
