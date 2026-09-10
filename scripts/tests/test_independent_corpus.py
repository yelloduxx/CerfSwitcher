import importlib.util
from pathlib import Path
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location("independent", Path(__file__).parents[1] / "prepare_independent_corpus.py")
CORPUS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CORPUS)


class IndependentCorpusTests(unittest.TestCase):
    def row(self, identity, document, en, ru):
        return dict(id=identity, documentID=document, texts=dict(en=en, ru=ru))

    def testWholeArticlesAndTranslationDuplicatesShareASplit(self):
        rows = [self.row("one", "https://example.org/a", "We keep the old draft.", "Сохраняем старый текст."),
                self.row("two", "https://example.org/a", "We will reply tomorrow.", "Ответим завтра."),
                self.row("three", "https://example.org/b", "WE  KEEP THE OLD DRAFT.", "Другой перевод."),
                self.row("four", "https://example.org/c", "A different translation.", "другой перевод.")]
        actual = CORPUS.partition_documents(rows)
        self.assertEqual(len({row["groupID"] for row in actual}), 1)
        self.assertEqual(len({row["split"] for row in actual}), 1)
        self.assertEqual({r["id"]: r["texts"] for r in rows}, {r["id"]: r["texts"] for r in actual})

    def testInputOrderCannotChangePartitionOrArchiveBytes(self):
        rows = [self.row(str(i), f"https://example.org/{i}", f"Sentence {i}.", f"Предложение {i}.") for i in range(40)]
        first = CORPUS.partition_documents(rows)
        second = CORPUS.partition_documents(list(reversed(rows)))
        self.assertEqual(first, second)
        self.assertEqual(CORPUS.encode_rows(first), CORPUS.encode_rows(second))
        self.assertEqual({r["split"] for r in first}, {"development", "calibration", "test"})

    def testForeignArchiveAndFrozenDestinationAreRejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "foreign.tar.gz"
            archive.write_bytes(b"not the pinned corpus")
            with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                CORPUS.load_source(archive)
            with self.assertRaisesRegex(ValueError, "refusing to overwrite"):
                CORPUS.prepare(archive, root / "unused-license", root)
            self.assertEqual(archive.read_bytes(), b"not the pinned corpus")


if __name__ == "__main__":
    unittest.main()
