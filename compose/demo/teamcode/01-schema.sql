-- SPDX-License-Identifier: Apache-2.0
-- Local demo only: the TeamCode tables `ostrom import teamcode` reads, with TeamCode's columns, types and keys
-- (teamcode infrastructure/database/tables: Teams, Members, Variants, VariantAssignments, McpToolPolicies, Accounts).
CREATE TABLE `teams` (
  `id` VARCHAR(36) NOT NULL PRIMARY KEY,
  `name` VARCHAR(120) NOT NULL
);

CREATE TABLE `members` (
  `id` VARCHAR(36) NOT NULL PRIMARY KEY,
  `team_id` VARCHAR(36) NOT NULL,
  `username` VARCHAR(64) NOT NULL,
  `password_hash` VARCHAR(255) NOT NULL,
  `role` VARCHAR(16) NOT NULL,
  `is_owner` BOOLEAN NOT NULL DEFAULT FALSE,
  `disabled` BOOLEAN NOT NULL DEFAULT FALSE,
  `must_change_password` BOOLEAN NOT NULL DEFAULT TRUE,
  `failed_logins` INT NOT NULL DEFAULT 0,
  `locked_until` BIGINT NOT NULL DEFAULT 0,
  CONSTRAINT `members_ibfk_1` FOREIGN KEY (`team_id`) REFERENCES `teams` (`id`),
  UNIQUE KEY `member_username` (`team_id`, `username`)
);

CREATE TABLE `variants` (
  `id` VARCHAR(36) NOT NULL PRIMARY KEY,
  `team_id` VARCHAR(36) NOT NULL,
  `kind` VARCHAR(16) NOT NULL,
  `target` VARCHAR(128) NOT NULL,
  `name` VARCHAR(120) NOT NULL,
  `binding` VARCHAR(16) NOT NULL,
  `version` INT NOT NULL,
  `endpoint` VARCHAR(2048) NULL,
  `config` TEXT NOT NULL,
  `shared_secret` TEXT NULL,
  `created_at` BIGINT NOT NULL,
  `updated_at` BIGINT NOT NULL,
  FOREIGN KEY (`team_id`) REFERENCES `teams` (`id`) ON DELETE CASCADE,
  UNIQUE KEY `variant_team_slot_name` (`team_id`, `kind`, `target`, `name`)
);

CREATE TABLE `mcp_tool_policies` (
  `variant_id` VARCHAR(36) NOT NULL PRIMARY KEY,
  `team_id` VARCHAR(36) NOT NULL,
  `mode` VARCHAR(16) NOT NULL,
  `tools` TEXT NOT NULL,
  `updated_at` BIGINT NOT NULL,
  FOREIGN KEY (`variant_id`) REFERENCES `variants` (`id`) ON DELETE CASCADE,
  FOREIGN KEY (`team_id`) REFERENCES `teams` (`id`) ON DELETE CASCADE,
  KEY `mcp_tool_policy_team` (`team_id`)
);

CREATE TABLE `variant_assignments` (
  `member_id` VARCHAR(36) NOT NULL,
  `kind` VARCHAR(16) NOT NULL,
  `target` VARCHAR(128) NOT NULL,
  `team_id` VARCHAR(36) NOT NULL,
  `variant_id` VARCHAR(36) NOT NULL,
  `source` VARCHAR(16) NOT NULL,
  `member_secret` TEXT NULL,
  `assigned_at` BIGINT NOT NULL,
  PRIMARY KEY (`member_id`, `kind`, `target`),
  FOREIGN KEY (`member_id`) REFERENCES `members` (`id`) ON DELETE CASCADE,
  FOREIGN KEY (`team_id`) REFERENCES `teams` (`id`) ON DELETE CASCADE,
  FOREIGN KEY (`variant_id`) REFERENCES `variants` (`id`) ON DELETE CASCADE,
  KEY `variant_assignment_variant` (`variant_id`),
  KEY `variant_assignment_team` (`team_id`, `member_id`)
);

CREATE TABLE `accounts` (
  `id` VARCHAR(36) NOT NULL PRIMARY KEY,
  `team_id` VARCHAR(36) NOT NULL,
  `provider` VARCHAR(32) NOT NULL,
  `provider_account_id` VARCHAR(128) NOT NULL,
  `organization_id` VARCHAR(128) NOT NULL,
  `display_name` VARCHAR(120) NOT NULL,
  `email` VARCHAR(320) NULL,
  `credential_version` BIGINT NOT NULL,
  `credential_envelope` MEDIUMTEXT NOT NULL,
  `disabled` BOOLEAN NOT NULL DEFAULT FALSE,
  `pool_id` VARCHAR(36) NULL,
  `priority` INT NOT NULL DEFAULT 0,
  `state` VARCHAR(32) NOT NULL,
  `cooldown_until` BIGINT NOT NULL DEFAULT 0,
  `refresh_pending` BOOLEAN NOT NULL DEFAULT FALSE,
  `refresh_started_at` BIGINT NOT NULL DEFAULT 0,
  `enrolled_by` VARCHAR(36) NULL,
  CONSTRAINT `accounts_ibfk_1` FOREIGN KEY (`team_id`) REFERENCES `teams` (`id`),
  UNIQUE KEY `provider_identity` (`team_id`, `provider`, `provider_account_id`, `organization_id`)
);
