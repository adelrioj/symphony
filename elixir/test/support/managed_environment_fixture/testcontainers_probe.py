import os

from testcontainers.core.config import testcontainers_config
from testcontainers.core.container import DockerContainer

IMAGE = "alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc"
RYUK_IMAGE = "testcontainers/ryuk:0.8.1@sha256:bf3f74a47dee0acda89aba4b2fc9c7fdcf994a084db02a2d06566f07baae022e"

testcontainers_config.ryuk_image = RYUK_IMAGE
qualification_id = os.environ["SYMPHONY_QUALIFICATION_ID"]

with DockerContainer(IMAGE).with_command("sleep 60").with_kwargs(
    labels={"symphony.dev/qualification": qualification_id}
) as container:
    code, output = container.exec(["sh", "-c", "printf testcontainers-ok"])
    if code != 0 or output.decode() != "testcontainers-ok":
        raise RuntimeError("Testcontainers command did not return the expected result")

print("testcontainers-ok")
