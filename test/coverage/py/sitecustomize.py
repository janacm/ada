# Python imports `sitecustomize` at startup from the first sys.path entry that
# has one. `./run-tests.sh --coverage` puts this directory on PYTHONPATH, so every
# python3 the suite spawns (the snooze daemon, the Paseo watcher, a component
# test) starts coverage.py itself, reading COVERAGE_PROCESS_START. Outside a
# coverage run this directory is not on the path and nothing here executes.
try:
    import coverage
except ImportError:
    pass
else:
    coverage.process_startup()
