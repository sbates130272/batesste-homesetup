/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * One-time setup for the Firefly III MariaDB/MySQL database.
 * Creates two views that flatten the double-entry accounting
 * model into simple tables for Grafana dashboard queries.
 *
 * Grafana connects using the existing 'firefly' database user
 * since root access is not available (MYSQL_RANDOM_ROOT_PASSWORD).
 *
 * Run against the Firefly III database:
 *
 *   docker exec -i <firefly_db_container> \
 *     mariadb -u firefly -p<FIREFLY_PASSWORD> firefly \
 *       < firefly-db-init.sql
 *
 * NOTE: MariaDB 12.x changed the default collation to
 * utf8mb4_uca1400_ai_ci. The Firefly tables use
 * utf8mb4_unicode_ci.  All string literals in view
 * definitions must carry an explicit COLLATE clause to
 * avoid "Illegal mix of collations" errors when Grafana
 * (whose connector negotiates uca1400) queries these views.
 */

/* ── View: analysis_txs ────────────────────────────────────── */
/*
 * Flattens the double-entry transaction model into one row per
 * transaction on an asset account.  Columns:
 *   date, email, account, category, meta_category,
 *   transaction_type, amount
 *
 * meta_category buckets each transaction into Income (deposits),
 * Expense (withdrawals with a category), Transfer (asset-to-asset
 * moves), or NULL (opening balances and uncategorised entries).
 *
 * Bank-imported transactions that are really internal transfers
 * (e.g. checking-to-savings) arrive as Withdrawals/Deposits.
 * The CASE detects these by category name and re-tags them as
 * 'Transfer' so they do not inflate income or expense totals.
 *
 * Workflow categories (e.g. "Needs Identified") are triage
 * markers, not real expense types.  They are tagged as
 * 'Workflow' so they are excluded from cash-flow analysis.
 */

CREATE OR REPLACE VIEW analysis_txs AS
SELECT CAST(tj.date AS DATE)   AS `date`,
       u.email                 AS email,
       a.name                  AS account,
       c.name                  AS category,
       CONVERT(
         CASE
           WHEN tt.type COLLATE utf8mb4_unicode_ci
                  = 'Opening balance'
                THEN NULL
           WHEN c.name COLLATE utf8mb4_unicode_ci IN (
                  'Financial - Transfers (Others)',
                  'Financial - Credit Card Payments',
                  'Financial - Transfer to HELOC',
                  'Financial - Transfer from HELOC',
                  'Financial - Transfer from HoldCo',
                  'Financial - Transfers to HoldCo',
                  'Investment - Valuation')
                THEN 'Transfer'
           WHEN c.name COLLATE utf8mb4_unicode_ci
                  LIKE 'Needs %'
             OR c.name COLLATE utf8mb4_unicode_ci
                  LIKE 'Need to %'
                THEN 'Workflow'
           WHEN tt.type COLLATE utf8mb4_unicode_ci
                  = 'Deposit'
                THEN 'Income'
           WHEN tt.type COLLATE utf8mb4_unicode_ci
                  = 'Transfer'
                THEN 'Transfer'
           WHEN tt.type COLLATE utf8mb4_unicode_ci
                  = 'Withdrawal'
                AND c.name IS NOT NULL
                THEN 'Expense'
           ELSE NULL
         END
       USING utf8mb4) COLLATE utf8mb4_unicode_ci
                               AS meta_category,
       tt.type                 AS transaction_type,
       ROUND(t.amount, 2)      AS amount
  FROM transactions t
  JOIN transaction_journals tj
    ON t.transaction_journal_id = tj.id
  JOIN transaction_types tt
    ON tt.id = tj.transaction_type_id
  LEFT JOIN category_transaction_journal ctj
    ON tj.id = ctj.transaction_journal_id
  LEFT JOIN categories c
    ON ctj.category_id = c.id
  JOIN accounts a
    ON a.id = t.account_id
  JOIN account_types at2
    ON a.account_type_id = at2.id
  JOIN users u
    ON a.user_id = u.id
 WHERE a.active        = 1
   AND a.deleted_at   IS NULL
   AND t.deleted_at   IS NULL
   AND at2.type COLLATE utf8mb4_unicode_ci = 'Asset account'
 ORDER BY tj.date DESC;

/* ── View: analysis_cash_flow ──────────────────────────────── */
/*
 * Filters analysis_txs to only Income, Expense, and NULL
 * (opening-balance / uncategorised) rows.  Transfers and
 * Workflow markers are excluded: transfers are internal
 * asset-to-asset moves that cancel to zero; workflow
 * categories are triage flags awaiting re-categorisation.
 */

CREATE OR REPLACE VIEW analysis_cash_flow AS
SELECT *
  FROM analysis_txs
 WHERE meta_category IS NULL
    OR meta_category COLLATE utf8mb4_unicode_ci
       IN ('Income', 'Expense');

/* ── Diagnostic queries (ad-hoc, not views) ────────────────── */
/*
 * Run these manually to identify data-quality issues.
 * They are NOT executed as part of the view setup above.
 */

/*
 * 1. Find withdrawals where both source and destination are
 *    asset accounts.  These are almost certainly transfers
 *    that were mis-entered.  Fix them in the Firefly UI by
 *    changing the transaction type to "Transfer".
 *
 *    SELECT tj.id, tj.date, tj.description,
 *           a_src.name  AS source,
 *           a_dst.name  AS destination,
 *           t_src.amount,
 *           c.name      AS category
 *      FROM transaction_journals tj
 *      JOIN transaction_types tt
 *        ON tt.id = tj.transaction_type_id
 *      JOIN transactions t_src
 *        ON t_src.transaction_journal_id = tj.id
 *       AND t_src.amount < 0
 *      JOIN transactions t_dst
 *        ON t_dst.transaction_journal_id = tj.id
 *       AND t_dst.amount > 0
 *      JOIN accounts a_src
 *        ON a_src.id = t_src.account_id
 *      JOIN accounts a_dst
 *        ON a_dst.id = t_dst.account_id
 *      JOIN account_types at_src
 *        ON a_src.account_type_id = at_src.id
 *      JOIN account_types at_dst
 *        ON a_dst.account_type_id = at_dst.id
 *      LEFT JOIN category_transaction_journal ctj
 *        ON tj.id = ctj.transaction_journal_id
 *      LEFT JOIN categories c
 *        ON ctj.category_id = c.id
 *     WHERE tt.type        = 'Withdrawal'
 *       AND at_src.type    = 'Asset account'
 *       AND at_dst.type    = 'Asset account'
 *       AND tj.deleted_at IS NULL;
 */

/*
 * 2. List every asset account with its current balance and
 *    active flag.  Useful for spotting accounts that should
 *    be deactivated.
 *
 *    SELECT a.name, at2.type, a.active,
 *           ROUND(SUM(t.amount), 2) AS balance
 *      FROM transactions t
 *      JOIN transaction_journals tj
 *        ON t.transaction_journal_id = tj.id
 *      JOIN accounts a
 *        ON a.id = t.account_id
 *      JOIN account_types at2
 *        ON a.account_type_id = at2.id
 *     WHERE at2.type      = 'Asset account'
 *       AND t.deleted_at IS NULL
 *       AND tj.deleted_at IS NULL
 *     GROUP BY a.id, a.name, at2.type, a.active
 *     ORDER BY a.active, balance;
 */
