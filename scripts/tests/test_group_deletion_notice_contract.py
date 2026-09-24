import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / "supabase/migrations/20260924090000_group_delete_notices_and_backup_member_compat.sql"
SCHEMA = ROOT / "supabase/schema.sql"


class GroupDeletionNoticeSqlContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.migration = MIGRATION.read_text(encoding="utf-8").lower()
        cls.schema = SCHEMA.read_text(encoding="utf-8").lower()

    def test_legacy_left_at_is_generated_from_removed_at(self):
        migration_pattern = re.compile(
            r"add column if not exists left_at\s+timestamptz\s+"
            r"generated always as\s*\(\s*removed_at\s*\) stored",
            re.DOTALL,
        )
        self.assertRegex(self.migration, migration_pattern)
        self.assertRegex(
            self.schema,
            re.compile(
                r"left_at\s+timestamptz\s+generated always as\s*\(\s*removed_at\s*\) stored",
                re.DOTALL,
            ),
        )

    def test_delete_trigger_is_leader_scoped_and_notices_active_other_members(self):
        function = self.migration.split(
            "create or replace function public.create_group_deletion_notices_before_delete()",
            1,
        )[1].split("revoke all on function", 1)[0]
        self.assertIn("security definer", function)
        self.assertIn("auth.uid() is null", function)
        self.assertIn("public.is_group_leader(old.id, auth.uid())", function)
        self.assertIn("gm.group_id = old.id", function)
        self.assertIn("gm.status = 'active'", function)
        self.assertIn("gm.user_id is distinct from auth.uid()", function)
        self.assertIn("before delete on public.groups", self.migration)
        self.assertIn("insert into public.group_deletion_notices", function)
        self.assertIn("before delete on public.groups", self.schema)

    def test_notices_are_outside_group_cascade_and_table_is_private(self):
        table = self.migration.split(
            "create table if not exists public.group_deletion_notices", 1
        )[1].split(";", 1)[0]
        self.assertNotIn("references public.groups", table)
        self.assertIn("references public.users (id) on delete cascade", table)
        self.assertIn("enable row level security", self.migration)
        self.assertIn(
            "revoke all on table public.group_deletion_notices from public, anon, authenticated",
            self.migration,
        )

    def test_list_and_ack_functions_are_recipient_scoped_and_explicitly_granted(self):
        for signature in (
            "public.list_my_group_deletion_notices()",
            "public.acknowledge_group_deletion_notice(uuid)",
            "public.create_group_deletion_notices_before_delete()",
        ):
            self.assertIn(
                f"revoke all on function {signature} from public, anon, authenticated",
                self.migration,
            )
        list_fn = self.migration.split(
            "create or replace function public.list_my_group_deletion_notices()", 1
        )[1].split("revoke all on function", 1)[0]
        ack_fn = self.migration.split(
            "create or replace function public.acknowledge_group_deletion_notice(notice_id_input uuid)",
            1,
        )[1].split("revoke all on function", 1)[0]
        self.assertIn("notice.recipient_user_id = auth.uid()", list_fn)
        self.assertIn("recipient_user_id = auth.uid()", ack_fn)
        self.assertIn(
            "grant execute on function public.list_my_group_deletion_notices() to authenticated",
            self.migration,
        )
        self.assertIn(
            "grant execute on function public.acknowledge_group_deletion_notice(uuid) to authenticated",
            self.migration,
        )

    def test_notices_are_created_in_group_delete_transaction(self):
        self.assertIn(
            "create trigger groups_create_deletion_notices\n  before delete on public.groups",
            self.migration,
        )
        self.assertIn("insert into public.group_deletion_notices", self.migration)
        # A BEFORE DELETE trigger runs in the same transaction as the row delete;
        # no separate queue/worker or out-of-transaction mechanism is involved.
        self.assertIn("create trigger groups_create_deletion_notices", self.schema)


if __name__ == "__main__":
    unittest.main()
