# Staff Scheduler — Koha Plugin

**Version:** 1.0.13
**Plugin class:** `Koha::Plugin::Com::LibSched::StaffScheduler`
**Compatible with:** Koha 22.05+ (tested on ByWater-hosted 24.x)

A staff scheduling tool that lives inside Koha. It pulls your staff
directory, branches, and holiday closures directly from Koha, and
stores its own assignments, task zones, and audit log in
plugin-owned tables. The UI is a single-page React app served
through Koha's standard plugin dispatcher (`run.pl`) — no separate
web service to run, no separate auth.

---

## Table of contents

1. [What it does](#what-it-does)
2. [Install / Upgrade / Uninstall](#install--upgrade--uninstall)
3. [Configuration](#configuration)
4. [Permissions model](#permissions-model)
5. [Concepts](#concepts)
6. [Where data lives](#where-data-lives)
7. [Reporting with Koha's SQL reports](#reporting-with-kohas-sql-reports)
   - [How to add a report](#how-to-add-a-report)
   - [Ready-to-paste reports](#ready-to-paste-reports)
8. [Troubleshooting](#troubleshooting)

---

## What it does

The plugin gives library staff a shared, day-by-day picture of who
is working where, and lets superlibrarians plan ahead.

- **Dashboard** — a daily timeline per staff member. Filter by
  role/team/branch/zone, sort by staff or location, click a block to
  edit. Superlibrarians can add new shifts inline.
- **Schedule** — batch-create *Branch Hours* or *Task Zone*
  assignments, with optional recurrence (weekly, every N weeks,
  monthly). Superlibrarians only.
- **Staff** — directory pulled live from Koha borrowers (filtered
  by category code, see Configuration). Click any staff member to
  see their week/month calendar.
- **Reports** — built-in views: coverage variance, zone utilization,
  daily headcount heatmap, full audit log.
- **Settings** — manage work zones and branch display colors.
  Branches/closures themselves come from Koha and are not editable
  here.

The plugin **never modifies** any Koha core tables. It only reads
from `borrowers`, `branches`, and `repeatable_holidays` /
`special_holidays`.

---

## Install / Upgrade / Uninstall

1. In Koha staff client, go to **Administration → Manage plugins**.
   (Requires `plugins.manage`, i.e. superlibrarian.)
2. Click **Upload plugin** and select the `.kpz` file.
3. Once uploaded, find "Staff Scheduler" in the list and click
   **Actions → Run tool**.
4. On first run the plugin's `install()` hook creates four tables
   (see [Where data lives](#where-data-lives)).
5. **Upgrades** are file-replace: upload a newer `.kpz` over the old
   one. The plugin's `upgrade()` hook re-runs `install()`, which uses
   `CREATE TABLE IF NOT EXISTS` so existing data is preserved.
6. **Uninstall** (from Manage plugins → Actions → Uninstall) drops
   all four plugin tables and all data they contain. Export anything
   you want to keep first.

> Staff who are not superlibrarians need the **Use tool plugins**
> permission (`tools` → `plugins_tool`) to open the scheduler. They
> do *not* need any other plugin permission.

---

## Configuration

**Administration → Manage plugins → Staff Scheduler → Configure**

| Setting | Purpose | Default |
|---|---|---|
| **Staff category code** | Which Koha borrower `categorycode` counts as "staff" for the directory. Anything not matching this code is filtered out. | `STAFF` |
| ~~Edit permission~~ | Retained for back-compat but **no longer consulted** as of v1.0.13. Writes are always superlibrarian-only. | n/a |

After saving, hard-refresh the scheduler tab once.

---

## Permissions model

As of v1.0.13:

| Action | Required permission |
|---|---|
| Open the scheduler / read the calendar / use filters | Logged in + `tools.plugins_tool` |
| Create or edit your **own task zone** assignments | Logged in + `tools.plugins_tool` |
| Delete your **own task zone** assignments | Logged in + `tools.plugins_tool` |
| Create/edit branch-hour shifts | **Superlibrarian** |
| Create/edit/delete **anyone else's** assignments | **Superlibrarian** |
| Recurring-series edits or deletes (multi-row) | **Superlibrarian** |
| Manage zones, branch colors | **Superlibrarian** |
| Run reports (in-app or via Koha SQL reports) | Whatever Koha grants for that surface |
| Upload / upgrade / uninstall the plugin | Superlibrarian (`plugins.manage`) |

All writes — by anyone — produce a row in
`koha_plugin_staffsched_audit`.

---

## Concepts

- **Shift** — a row in `koha_plugin_staffsched_assignments` covering
  one employee, one date, and a start/end time window.
- Two kinds of shift:
  - **Branch hours** (`is_base_shift = 1`, `location_id` set) —
    "this person is working at this branch from X to Y". This is the
    baseline; nothing else can overlap outside it.
  - **Task zones** (`is_base_shift = 0`, `zone_id` set) — a more
    specific assignment *inside* a branch-hour window (e.g.
    "Reference Desk", "Children's Programming"). Task zones must
    fall within an existing branch-hour window for the same
    employee on the same day.
- **Out marker** — a branch shift whose `location_id` is the
  sentinel `__OUT__`. Setting someone to Out for a day clears all
  their other assignments for that day automatically.
- **Series** — recurring shifts share a `series_id` UUID. Editing
  or deleting a series with `after_date` set affects every row in
  that series on or after that date.
- **Closures** come from Koha's `repeatable_holidays` and
  `special_holidays` tables. They appear as read-only blocks on
  the calendar.

---

## Where data lives

The plugin owns four tables. All names are prefixed
`koha_plugin_staffsched_`.

### `koha_plugin_staffsched_assignments`

The shift table. One row per shift.

| Column | Type | Notes |
|---|---|---|
| `id` | VARCHAR(36) PK | UUID |
| `employee_id` | INT | `borrowers.borrowernumber` |
| `zone_id` | VARCHAR(36) NULL | FK to `..._zones.id` (NULL for branch hours) |
| `location_id` | VARCHAR(10) NULL | `branches.branchcode` or `__OUT__` (NULL for task zones) |
| `shift_date` | DATE | |
| `start_time` | TIME | |
| `end_time` | TIME | |
| `is_base_shift` | TINYINT(1) | 1 = branch hours, 0 = task zone |
| `series_id` | VARCHAR(36) NULL | shared by all rows of a recurring series |
| `custom_label` | VARCHAR(255) NULL | optional display override |
| `notes` | TEXT NULL | |
| `created_at` / `updated_at` | DATETIME | |

Indexes: `(employee_id, shift_date)`, `(series_id)`, `(shift_date)`.

### `koha_plugin_staffsched_zones`

Work zones (e.g. "Reference Desk", "Programming Room").

| Column | Type | Notes |
|---|---|---|
| `id` | VARCHAR(36) PK | UUID |
| `name` | VARCHAR(255) | |
| `color_code` | VARCHAR(7) | hex, e.g. `#bbf7d0` |
| `is_active` | TINYINT(1) | soft-delete flag |
| `created_at` | DATETIME | |

### `koha_plugin_staffsched_branch_colors`

Optional color override per Koha branch (for the calendar).

| Column | Type | Notes |
|---|---|---|
| `branchcode` | VARCHAR(10) PK | matches `branches.branchcode` |
| `color_code` | VARCHAR(7) | hex |

### `koha_plugin_staffsched_audit`

Every create/update/delete on assignments writes one row.

| Column | Type | Notes |
|---|---|---|
| `id` | INT AUTO_INCREMENT PK | |
| `employee_id` | INT NULL | the employee whose shift was affected |
| `action_type` | VARCHAR(100) | e.g. `ZONE_SHIFT_CREATE`, `BRANCH_SHIFT_UPDATE`, `ZONE_SHIFT_DELETE` |
| `details` | TEXT | human-readable summary, e.g. `"Created 2026-05-28 09:00-17:00"` |
| `changed_by` | VARCHAR(255) | display name of the Koha user who made the change |
| `created_at` | DATETIME | |

Indexes: `(employee_id)`, `(created_at)`.

---

## Reporting with Koha's SQL reports

Because all scheduler data lives in regular Koha database tables,
you can query it from **Tools → Reports → Create from SQL** just
like any other Koha report. You also get to join against Koha's own
`borrowers`, `branches`, and holiday tables for richer output.

### How to add a report

1. **Tools → Reports → Guided reports wizard → Create from SQL.**
2. Fill in **Name**, **Group** (e.g. "Staff Scheduler"), and
   **Notes**.
3. Paste a query (examples below). Use `<<Date|date>>` and similar
   runtime parameters as needed.
4. Save, then **Run report**. Reports can be scheduled, saved as
   public, or exported to CSV.

> Tip: prefix all your scheduler reports with `[Sched]` in the Name
> field so they're easy to find later.

### Ready-to-paste reports

All queries are tested against MariaDB 10.5+ (Koha's standard
backend). Replace `<<...>>` placeholders with the Koha report
parameter syntax (date pickers, text inputs, etc.) when you save
them.

#### 1. Daily schedule for a given date

```sql
SELECT
    b.surname, b.firstname,
    a.shift_date,
    a.start_time, a.end_time,
    CASE WHEN a.is_base_shift = 1 THEN 'Branch hours' ELSE 'Task zone' END AS shift_type,
    COALESCE(br.branchname, a.location_id) AS branch,
    z.name AS zone,
    a.custom_label,
    a.notes
FROM   koha_plugin_staffsched_assignments a
JOIN   borrowers b               ON b.borrowernumber = a.employee_id
LEFT  JOIN branches br            ON br.branchcode    = a.location_id
LEFT  JOIN koha_plugin_staffsched_zones z ON z.id     = a.zone_id
WHERE  a.shift_date = <<Schedule date|date>>
ORDER  BY b.surname, b.firstname, a.start_time;
```

#### 2. Hours worked per staff member in a date range

Sums branch-hour shifts only (task zones nest *inside* branch hours
and would double-count).

```sql
SELECT
    b.borrowernumber,
    CONCAT(b.surname, ', ', b.firstname) AS staff,
    SUM(TIME_TO_SEC(TIMEDIFF(a.end_time, a.start_time))/3600.0) AS hours,
    COUNT(*) AS shifts
FROM   koha_plugin_staffsched_assignments a
JOIN   borrowers b ON b.borrowernumber = a.employee_id
WHERE  a.is_base_shift = 1
  AND  a.location_id  <> '__OUT__'
  AND  a.shift_date BETWEEN <<From|date>> AND <<To|date>>
GROUP  BY b.borrowernumber, b.surname, b.firstname
ORDER  BY hours DESC;
```

#### 3. Branch coverage — staff-hours per branch, per day

```sql
SELECT
    a.shift_date,
    br.branchname,
    COUNT(DISTINCT a.employee_id) AS distinct_staff,
    ROUND(SUM(TIME_TO_SEC(TIMEDIFF(a.end_time, a.start_time))/3600.0), 2) AS staff_hours
FROM   koha_plugin_staffsched_assignments a
JOIN   branches br ON br.branchcode = a.location_id
WHERE  a.is_base_shift = 1
  AND  a.location_id  <> '__OUT__'
  AND  a.shift_date BETWEEN <<From|date>> AND <<To|date>>
GROUP  BY a.shift_date, br.branchcode, br.branchname
ORDER  BY a.shift_date, br.branchname;
```

#### 4. Zone utilization — hours by task zone

```sql
SELECT
    z.name AS zone,
    COUNT(*)                       AS shifts,
    COUNT(DISTINCT a.employee_id)  AS distinct_staff,
    ROUND(SUM(TIME_TO_SEC(TIMEDIFF(a.end_time, a.start_time))/3600.0), 2) AS staff_hours
FROM   koha_plugin_staffsched_assignments a
JOIN   koha_plugin_staffsched_zones z ON z.id = a.zone_id
WHERE  a.is_base_shift = 0
  AND  a.shift_date BETWEEN <<From|date>> AND <<To|date>>
GROUP  BY z.id, z.name
ORDER  BY staff_hours DESC;
```

#### 5. "Out" / time-off summary per staff in a range

```sql
SELECT
    CONCAT(b.surname, ', ', b.firstname) AS staff,
    COUNT(*) AS out_days,
    GROUP_CONCAT(a.shift_date ORDER BY a.shift_date SEPARATOR ', ') AS dates
FROM   koha_plugin_staffsched_assignments a
JOIN   borrowers b ON b.borrowernumber = a.employee_id
WHERE  a.is_base_shift = 1
  AND  a.location_id   = '__OUT__'
  AND  a.shift_date BETWEEN <<From|date>> AND <<To|date>>
GROUP  BY b.borrowernumber, b.surname, b.firstname
ORDER  BY out_days DESC;
```

#### 6. Uncovered branch-hour windows missing any task zone

Finds branch-hour shifts longer than N hours that have *no* task
zones nested inside them — useful for spotting unassigned floor
time.

```sql
SELECT
    b.surname, b.firstname,
    a.shift_date,
    a.start_time, a.end_time,
    br.branchname
FROM   koha_plugin_staffsched_assignments a
JOIN   borrowers b  ON b.borrowernumber = a.employee_id
JOIN   branches  br ON br.branchcode    = a.location_id
WHERE  a.is_base_shift = 1
  AND  a.location_id  <> '__OUT__'
  AND  a.shift_date BETWEEN <<From|date>> AND <<To|date>>
  AND  TIME_TO_SEC(TIMEDIFF(a.end_time, a.start_time))/3600.0 >= <<Min branch-hour length (hours)|integer>>
  AND  NOT EXISTS (
        SELECT 1
        FROM   koha_plugin_staffsched_assignments z
        WHERE  z.is_base_shift = 0
          AND  z.employee_id   = a.employee_id
          AND  z.shift_date    = a.shift_date
          AND  z.start_time   <  a.end_time
          AND  z.end_time     >  a.start_time
       )
ORDER  BY a.shift_date, b.surname;
```

#### 7. Recent audit-log activity

```sql
SELECT
    al.created_at,
    al.changed_by,
    al.action_type,
    CONCAT(b.surname, ', ', b.firstname) AS affected_staff,
    al.details
FROM   koha_plugin_staffsched_audit al
LEFT  JOIN borrowers b ON b.borrowernumber = al.employee_id
WHERE  al.created_at >= <<Since|date>>
ORDER  BY al.created_at DESC
LIMIT  <<Max rows|integer>>;
```

#### 8. Changes made by a specific user

```sql
SELECT
    al.created_at,
    al.action_type,
    CONCAT(b.surname, ', ', b.firstname) AS affected_staff,
    al.details
FROM   koha_plugin_staffsched_audit al
LEFT  JOIN borrowers b ON b.borrowernumber = al.employee_id
WHERE  al.changed_by LIKE CONCAT('%', <<User name (partial match)|text>>, '%')
  AND  al.created_at BETWEEN <<From|date>> AND <<To|date>>
ORDER  BY al.created_at DESC;
```

#### 9. Shifts scheduled on a Koha-defined holiday

Cross-references the scheduler against Koha's own holiday tables —
useful for catching staff inadvertently scheduled on a closure.

```sql
SELECT
    a.shift_date,
    br.branchname,
    CONCAT(b.surname, ', ', b.firstname) AS staff,
    a.start_time, a.end_time,
    COALESCE(sh.title, rh.title) AS holiday
FROM   koha_plugin_staffsched_assignments a
JOIN   borrowers b  ON b.borrowernumber = a.employee_id
JOIN   branches  br ON br.branchcode    = a.location_id
LEFT  JOIN special_holidays sh
       ON sh.branchcode = a.location_id
      AND sh.day        = DAY(a.shift_date)
      AND sh.month      = MONTH(a.shift_date)
      AND sh.year       = YEAR(a.shift_date)
LEFT  JOIN repeatable_holidays rh
       ON rh.branchcode = a.location_id
      AND ((rh.day      = DAY(a.shift_date) AND rh.month = MONTH(a.shift_date))
        OR  rh.weekday  = WEEKDAY(a.shift_date))
WHERE  (sh.idholiday IS NOT NULL OR rh.id IS NOT NULL)
  AND  a.is_base_shift = 1
  AND  a.location_id  <> '__OUT__'
  AND  a.shift_date BETWEEN <<From|date>> AND <<To|date>>
ORDER  BY a.shift_date, br.branchname, b.surname;
```

#### 10. Weekly headcount heatmap (one row per date, columns per branch)

```sql
SELECT
    a.shift_date,
    SUM(CASE WHEN a.location_id = 'MAIN'   THEN 1 ELSE 0 END) AS main,
    SUM(CASE WHEN a.location_id = 'BRANCH' THEN 1 ELSE 0 END) AS branch
FROM   koha_plugin_staffsched_assignments a
WHERE  a.is_base_shift = 1
  AND  a.location_id  <> '__OUT__'
  AND  a.shift_date BETWEEN <<Week start|date>> AND DATE_ADD(<<Week start|date>>, INTERVAL 6 DAY)
GROUP  BY a.shift_date
ORDER  BY a.shift_date;
```

> Edit the `CASE WHEN a.location_id = '…'` lines to match your
> actual branch codes (look them up in
> **Administration → Libraries**).

---

## Troubleshooting

**"Access denied" page when a non-superlib opens the tool**
Make sure that user's patron category has **Use tool plugins**
(`tools.plugins_tool`) enabled under **Patrons → Permissions**.

**"Couldn't load some scheduler data" red banner**
The banner lists which endpoints failed and shows the HTTP status,
content-type, byte count, and a preview. The most common causes are
expired Koha sessions (log out and back in) and missing tables
(re-run the plugin install).

**Stale UI after upgrade**
Hard-refresh the scheduler tab (Ctrl/Cmd-Shift-R). The bundle URL
includes the plugin version so a real upgrade busts the cache, but
the *tool HTML* itself can sit in browser cache for a short window.

**Branch-hour vs. task-zone confusion**
A task zone *must* sit inside an existing branch-hour window for
the same employee on the same day. If you can't create a task zone
at a given time, check that the employee has a branch-hour shift
covering that time first.

**Setting someone to "Out" wiped other assignments**
This is intentional — Out is a sentinel that means "not working
today". It clears the day's other assignments to keep the calendar
consistent. The wipe is logged in the audit table.

---

## Version history (recent)

- **1.0.13** — Lock all admin writes to superlibrarian-only; the
  Configure page's edit-permission toggle is no longer consulted.
- **1.0.12** — Route the JSON API through `method=tool` so the
  `tools.plugins_tool` permission is enough; previously every API
  call required `plugins.manage` (superlibrarian).
- **1.0.11** — Diagnostic error messages: API failures show HTTP
  status, content-type, byte count, and a printable preview.
- **1.0.10** — Server-side per-row write checks; non-admin staff
  can mutate only their own task zones; every mutation audited.
- **1.0.9** — "Out" override only deletes overlapping task zones
  for the affected employee, not the whole day's calendar.
- **1.0.8** — Dashboard tolerates partial API failures: shows a red
  banner naming the failed endpoints instead of a blank screen.
