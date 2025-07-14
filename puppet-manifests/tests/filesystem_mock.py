#
# Copyright (c) 2025 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#

import io

# Keys for filesystem node properties
PARENT = "parent"
TYPE = "type"
FILE = "file"
DIR = "dir"
LINK = "link"
CONTENTS = "contents"
TARGET = "target"
REF = "ref"
LISTENERS = "listeners"


class FilesystemMockError(BaseException):
    pass


class FileMock():
    def __init__(self, fs, entry):
        self.fs = fs
        self.entry = entry

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        pass

    def readlines(self):
        lines = self.entry[CONTENTS].split("\n")
        out_lines = [line + "\n" for line in lines[:-1]]
        if len(lines[-1]) > 0:
            out_lines.append(lines[-1])
        return out_lines

    def read(self):
        return self.entry[CONTENTS]

    def write(self, contents):
        if REF not in self.entry:
            raise io.UnsupportedOperation("not writable")
        self.entry[CONTENTS] += contents


class ReadOnlyFileContainer():
    def __init__(self, contents=None):
        self.next_id = 0
        self.root = self._get_new_dir(None)
        if contents:
            self.batch_add(contents)

    def batch_add(self, contents):
        for path, data in contents.items():
            if data is None:
                self._add_dir(path)
            elif type(data) == str:
                self._add_file(path, data)
            elif type(data) == tuple and len(data) == 1 and type(data[0]) == str:
                self._add_link(path, data[0])
            else:
                raise FilesystemMockError("Invalid entry, must be None for directory, "
                                          "str for file or tuple with 1 str element for link")

    def get_root_node(self):
        return self.root

    @staticmethod
    def _get_new_dir(parent):
        return {PARENT: parent, TYPE: DIR, CONTENTS: dict()}

    @staticmethod
    def _get_new_file(parent, contents):
        return {PARENT: parent, TYPE: FILE, CONTENTS: contents}

    @staticmethod
    def _get_new_link(parent, entry, target_path):
        return {PARENT: parent, TYPE: LINK, CONTENTS: entry, TARGET: target_path}

    def _do_add_dir(self, path_pieces):
        def add_dir_rec(parent, pieces):
            if len(pieces) == 0:
                return parent
            current = parent[CONTENTS].get(pieces[0], None)
            if not current:
                current = self._get_new_dir(parent)
                parent[CONTENTS][pieces[0]] = current
            return add_dir_rec(current, pieces[1:])
        return add_dir_rec(self.root, path_pieces)

    def _get_entry(self, path):
        pieces = path.split("/")[1:]

        def get_entry_rec(parent, pieces):
            if len(pieces) == 0:
                return parent
            current = parent[CONTENTS].get(pieces[0], None)
            if not current:
                raise FilesystemMockError(f"Path not found: '{path}'")
            return get_entry_rec(current, pieces[1:])

        return get_entry_rec(self.root, pieces)

    def _add_dir(self, path):
        pieces = path.split("/")[1:]
        self._do_add_dir(pieces)

    def _add_file(self, path, contents):
        pieces = path.split("/")[1:]
        new_dir = self._do_add_dir(pieces[:-1])
        file_entry = self._get_new_file(new_dir, contents)
        new_dir[CONTENTS][pieces[-1]] = file_entry

    def _add_link(self, path, ref_path):
        pieces = path.split("/")[1:]
        new_dir = self._do_add_dir(pieces[:-1])
        ref_entry = self._get_entry(ref_path)
        link_entry = self._get_new_link(new_dir, ref_entry, ref_path)
        new_dir[CONTENTS][pieces[-1]] = link_entry


class FilesystemMock():
    def __init__(self, contents: dict = None, fs: ReadOnlyFileContainer = None):
        if fs is not None:
            self.fs = fs
            add_contents = True
        else:
            self.fs = ReadOnlyFileContainer(contents)
            add_contents = False

        self.root = self._get_new_entry(self.fs.get_root_node(), None)
        if add_contents and contents:
            self.batch_add(contents)

    def batch_add(self, contents):
        for path, data in contents.items():
            if data is None:
                self.create_directory(path)
            elif type(data) == str:
                self.set_file_contents(path, data)
            elif type(data) == tuple and len(data) == 1 and type(data[0]) == str:
                self.set_link_contents(path, data[0])
            else:
                raise FilesystemMockError("Invalid entry, must be None for directory, "
                                          "str for file or tuple with 1 str element for link")

    @staticmethod
    def _get_new_entry(ref, parent, node_type=None):
        if not node_type:
            node_type = ref[TYPE]
        entry = {REF: ref, PARENT: parent, TYPE: node_type}
        if node_type == DIR:
            entry[CONTENTS] = ref[CONTENTS].copy() if ref else dict()
        elif node_type == LINK:
            entry[CONTENTS] = ref[CONTENTS] if ref else None
            entry[TARGET] = ref[TARGET] if ref else None
        else:
            entry[CONTENTS] = ''
        return entry

    def _get_entry(self, path, translate_link=False):
        pieces = path.split("/")[1:]

        def get_entry_rec(contents, pieces):
            if len(pieces) == 0:
                if translate_link and contents[TYPE] == LINK:
                    return contents[CONTENTS]
                return contents
            if contents[TYPE] == LINK:
                contents = contents[CONTENTS]
            if REF in contents and contents[CONTENTS] is None:
                child = contents[REF][CONTENTS].get(pieces[0], None)
            else:
                child = contents[CONTENTS].get(pieces[0], None)
            if child is None:
                return None
            return get_entry_rec(child, pieces[1:])

        return get_entry_rec(self.root, pieces)

    def _patch_entry(self, path, node_type):
        pieces = path.split("/")[1:]

        def translate_link(entry):
            target = entry[CONTENTS]
            if REF not in target:
                target = self._patch_entry(entry[TARGET], target[TYPE])
                entry[CONTENTS] = target
            return target

        def patch_entry_rec(level, entry, pieces):
            if len(pieces) == 0:
                if entry[TYPE] == LINK and node_type != LINK:
                    entry = translate_link(entry)
                if entry[TYPE] != node_type:
                    if node_type == FILE:
                        raise IsADirectoryError(f"[Errno 21] Is a directory: '{path}'")
                    raise NotADirectoryError(f"[Errno 20] Not a directory: '{path}'")
                return entry
            if entry[TYPE] == LINK:
                entry = translate_link(entry)
            if entry[TYPE] != DIR:
                raise NotADirectoryError(f"[Errno 20] Not a directory: '{path}'")
            if entry[CONTENTS] is None:
                entry[CONTENTS] = entry[REF][CONTENTS].copy()
            child = entry[CONTENTS].get(pieces[0], None)
            if child is None or REF not in child:
                if child is None:
                    new_type = node_type if len(pieces) == 1 else DIR
                    child = self._get_new_entry(None, entry, new_type)
                else:
                    child = self._get_new_entry(child, entry)
                entry[CONTENTS][pieces[0]] = child
            return patch_entry_rec(level + 1, child, pieces[1:])

        return patch_entry_rec(0, self.root, pieces)

    def exists(self, path):
        entry = self._get_entry(path)
        return entry is not None

    def isfile(self, path):
        entry = self._get_entry(path)
        return entry and entry[TYPE] == FILE

    def isdir(self, path):
        entry = self._get_entry(path)
        return entry and entry[TYPE] == DIR

    def islink(self, path):
        entry = self._get_entry(path)
        return entry and entry[TYPE] == LINK

    def open(self, path, mode="r"):
        if "w" in mode:
            entry = self._patch_entry(path, FILE)
        else:
            entry = self._get_entry(path, translate_link=True)
            if not entry:
                raise FileNotFoundError(f"[Errno 2] No such file or directory: '{path}'")
        if entry[TYPE] == DIR:
            raise IsADirectoryError(f"[Errno 21] Is a directory: '{path}'")
        if "w" in mode:
            self._call_listeners(entry)
        return FileMock(self, entry)

    def _call_listeners(self, entry):
        if parent := entry[PARENT]:
            self._call_listeners(parent)
        if listeners := entry.get(LISTENERS, None):
            for listener in listeners:
                listener()

    def create_directory(self, path):
        entry = self._patch_entry(path, DIR)
        self._call_listeners(entry)

    def set_file_contents(self, path, contents):
        entry = self._patch_entry(path, FILE)
        entry[CONTENTS] = contents
        self._call_listeners(entry)

    def get_file_contents(self, path):
        entry = self._get_entry(path, translate_link=True)
        if entry is None:
            raise FilesystemMockError("Path does not exist")
        if entry[TYPE] != FILE:
            raise FilesystemMockError("Path is not a file")
        return entry[CONTENTS]

    def set_link_contents(self, link_path, target_path):
        target = self._get_entry(target_path)
        if target is None:
            raise FilesystemMockError("Target path does not exist")
        entry = self._patch_entry(link_path, LINK)
        entry[CONTENTS] = target
        entry[TARGET] = target_path
        self._call_listeners(entry)

    def listdir(self, path):
        entry = self._get_entry(path, translate_link=True)
        if entry is None:
            raise FilesystemMockError("Path does not exist")
        if entry[TYPE] != DIR:
            raise FilesystemMockError("Path is not a directory")
        files = []
        for name, child in entry[CONTENTS].items():
            if child[TYPE] == FILE:
                files.append(name)
        files.sort()
        return files

    def add_listener(self, path, callback):
        entry = self._get_entry(path, translate_link=True)
        if entry is None:
            raise FilesystemMockError("Path does not exist")
        if REF not in entry:
            entry = self._patch_entry(path, entry[TYPE])
        listeners = entry.setdefault(LISTENERS, list())
        listeners.append(callback)

    def delete(self, path):
        pieces = path.split("/")[1:]

        entry = self._get_entry(path)
        if entry is None:
            raise FileNotFoundError(f"[Errno 2] No such file or directory: '{path}'")

        pieces = path.split("/")
        patched_entry = self._patch_entry("/".join(pieces[:-1]), DIR)
        patched_entry[CONTENTS].pop(pieces[-1])
        self._call_listeners(patched_entry)
