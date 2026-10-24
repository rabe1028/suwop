"""Embed text and images with the converted models, using transformers' preprocessing."""

import coremltools as ct
import numpy as np
from convert import LENGTH, load

IMAGE_TOKEN = 258880


class Pipeline:
    def __init__(self, root, directory, precision, units=ct.ComputeUnit.CPU_AND_NE):
        _, self.st = load(root)

        def model(name, compute=units):
            return ct.models.MLModel(f"{directory}/{name}.mlpackage", compute_units=compute)

        self.vision_encoder = model(f"vision-encoder-{precision}")
        # fp16 models must not fall back to the CPU: its fp16 arithmetic corrupts them.
        self.vision_head = model("vision-head-fp32", ct.ComputeUnit.CPU_ONLY)
        self.tokens = model(f"tokens-{precision}", ct.ComputeUnit.CPU_ONLY)
        self.encoder = model(f"encoder-{precision}")

    def _embeddings(self, ids):
        padded = np.zeros((1, LENGTH), np.int32)
        padded[0, : len(ids)] = ids
        return self.tokens.predict({"input_ids": padded})["inputs_embeds"]

    def _encode(self, embeds, count):
        mask = np.zeros((1, LENGTH), np.float32)
        mask[0, :count] = 1
        vector = self.encoder.predict({"inputs_embeds": embeds.astype(np.float32), "mask": mask})[
            "embedding"
        ][0]
        return vector / np.linalg.norm(vector)

    def text(self, text):
        ids = self.st.preprocess([text])["input_ids"][0].numpy()
        if len(ids) > LENGTH:
            raise ValueError("Query exceeds the converted sequence length")
        return self._encode(self._embeddings(ids), len(ids))

    def image(self, path):
        features = self.st.preprocess([{"image": path}])
        ids = features["input_ids"][0].numpy()
        positions = features["image_position_ids"].int().numpy()
        pixels = features["pixel_values"].float().numpy()
        count = int((positions[0] != -1).all(-1).sum()) // 9
        slots = np.flatnonzero(ids == IMAGE_TOKEN)
        if len(slots) != count:
            raise ValueError("Soft token count does not match image placeholders")
        hidden = self.vision_encoder.predict({"pixel_values": pixels, "position_ids": positions})[
            "hidden"
        ]
        soft = self.vision_head.predict({"hidden": hidden, "position_ids": positions})[
            "soft_tokens"
        ][0, :count]
        # Placeholders take the pad embedding before soft tokens replace them.
        embeds = self._embeddings(np.where(ids == IMAGE_TOKEN, 0, ids))
        embeds[0, slots] = soft
        return self._encode(embeds, len(ids))
