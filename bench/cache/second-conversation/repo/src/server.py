import os
import tomllib


def load_config():
    env = os.environ.get("APP_ENV", "default")
    with open(f"config/{env}.toml", "rb") as f:
        return tomllib.load(f)["server"]
