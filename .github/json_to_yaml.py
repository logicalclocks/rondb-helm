import json
import yaml


# Use this script to transform the values.schema.json file into a values.yaml file.


def extract_defaults(schema, parent_is_array=False, parent_key=""):
    """Recursively extract default values from a JSON schema."""
    defaults = {}
    if isinstance(schema, dict):
        for key, value in schema.items():
            if key == "default":
                return value  # Base case: Return the default value.
            elif key == "properties":
                # Traverse the properties of the schema.
                for prop, prop_schema in value.items():
                    defaults[prop] = extract_defaults(prop_schema, parent_key=prop)
            elif key == "items" and isinstance(value, dict):
                # Handle array defaults.
                defaults = [
                    extract_defaults(value, parent_is_array=True, parent_key=parent_key)
                ]

        # Note that these defaults could be interfer with other restrictions.
        if not defaults and "type" in schema:
            if not parent_is_array:
                print(f"Warning: No default value found for '{parent_key}'")
            # Handle default values for primitive types.
            if "null" in schema["type"]:
                defaults = None
            elif schema["type"] == "integer" or "integer" in schema["type"]:
                defaults = 0
            elif schema["type"] == "number" or "number" in schema["type"]:
                defaults = 0
            elif schema["type"] == "boolean" or "boolean" in schema["type"]:
                defaults = False
            elif schema["type"] == "string" or "string" in schema["type"]:
                defaults = ""

    return defaults


# Load JSON schema
with open("values.schema.json", "r") as f:
    json_schema = json.load(f)

# Extract defaults
defaults = extract_defaults(json_schema)

# Save to YAML
with open("values_sorted.yaml", "w") as f:
    yaml.dump(defaults, f, default_flow_style=False)

print("Defaults extracted and saved to values.yaml.")
