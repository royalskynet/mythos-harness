"""11-08：多 profile gateway 行程的 HERMES_HOME 指向 ~/.hermes；外掛的 state.db 仍須是本 profile 的庫。"""
import importlib.util, os
os.environ["HERMES_HOME"] = "/nonexistent-host-home"
os.environ.pop("MYTHOS_STATE_DB", None)
here = os.path.dirname(os.path.abspath(__file__))
profile = os.path.dirname(os.path.dirname(here))
for name in ("adhd-outlet", "mythos-tools"):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), os.path.join(profile, "plugins", name, "__init__.py"))
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    assert m.STATE_DB == os.path.join(profile, "state.db"), (name, m.STATE_DB)
print("PROFILE_DB_OK")
