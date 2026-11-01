import sqlite3
import tempfile
import unittest
from contextlib import closing
from pathlib import Path
from orbit_classera_monitor import Store, report_date


class ReportTitleDateTests(unittest.TestCase):
    def test_explicit_slash_dates_validate_and_do_not_guess_year(self):
        self.assertEqual(report_date('12F 1/11/26', True), '2026-11-01')
        self.assertEqual(report_date('12E 29/2/2024', True), '2024-02-29')
        self.assertIsNone(report_date('12F 29/2/26', True))
        self.assertIsNone(report_date('12F 1/11', True))

    def test_history_filter_and_statistics_resolve_title_without_writing_database(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            db, people = root / 'delivery.db', root / 'people.db'
            sqlite3.connect(db).close()
            with closing(sqlite3.connect(people)) as connection, connection:
                connection.execute('CREATE TABLE subscribers(phone TEXT,name TEXT,class_name TEXT)')
                connection.execute("INSERT INTO subscribers VALUES ('201000000001','Fixture','12F')")
            store = Store(db, people)
            store.migrate()
            with closing(sqlite3.connect(db)) as connection, connection:
                connection.execute("INSERT INTO orbit_delivery_attempts(id,report,report_date,class_id,phone,status,updated_at,historical) VALUES ('fixture','12F 1/11/26',NULL,'12F','201000000001','read',1,1)")
            history = store.history({'from': '2026-11-01', 'to': '2026-11-01'})
            self.assertEqual(history['total'], 1)
            self.assertEqual(history['records'][0]['report_date'], '2026-11-01')
            self.assertEqual(history['records'][0]['report_date_source'], 'title')
            stats = store.statistics({'from': '2026-11-01', 'to': '2026-11-01'})
            self.assertEqual(stats['counts']['read'], 1)
            self.assertIsNone(stats['expected'])
            self.assertIsNone(stats['delivery_rate'])
            with closing(sqlite3.connect(db)) as connection, connection:
                self.assertIsNone(connection.execute("SELECT report_date FROM orbit_delivery_attempts WHERE id='fixture'").fetchone()[0])

            # Empty stored dates resolve consistently in filtering and presentation.
            with closing(sqlite3.connect(db)) as connection, connection:
                connection.execute("UPDATE orbit_delivery_attempts SET report_date='' WHERE id='fixture'")
            self.assertEqual(store.history({'from': '2026-11-01'})['total'], 1)

            # A recorded date remains authoritative even when the title differs.
            with closing(sqlite3.connect(db)) as connection, connection:
                connection.execute("UPDATE orbit_delivery_attempts SET report_date='2026-10-31' WHERE id='fixture'")
            self.assertEqual(store.history({'from': '2026-11-01'})['total'], 0)
            row = store.history({'to': '2026-10-31'})['records'][0]
            self.assertEqual(row['report_date'], '2026-10-31')
            self.assertEqual(row['report_date_source'], 'stored')


if __name__ == '__main__':
    unittest.main()
