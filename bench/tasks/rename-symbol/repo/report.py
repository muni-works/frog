from users import get_usr


def describe(uid):
    return f"user: {get_usr(uid)}"
