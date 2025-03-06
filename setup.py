# setup.py
from setuptools import setup, find_packages

with open("requirements.txt") as f:
    required = f.read().splitlines()

setup(
    name="rw_workspace_utils_keywords",
    version=open("VERSION").read().strip(),  # ensure no trailing newline
    packages=["RW"],
    package_dir={"RW": "RW"},
    description="A set of RunWhen published workspace utilities keywords for the RunWhen Platform.",
    long_description=open("README.md").read(),
    long_description_content_type="text/markdown",
    author="RunWhen",
    author_email="info@runwhen.com",
    url="https://github.com/runwhen-contrib/rw-cli-codecollection",
    install_requires=required,
    include_package_data=True,
    classifiers=[
        "Programming Language :: Python :: 3",
        "License :: OSI Approved :: Apache Software License",
    ],
    # The CRUCIAL piece for modern PyPI acceptance:
    license_files=["LICENSE"],
)
