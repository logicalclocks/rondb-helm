import json
import yaml
import jsonref
import sys

# Use this script to transform the values.schema.json file into a values.yaml file.

some_defaults_not_found = False

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
                global some_defaults_not_found
                some_defaults_not_found = True

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


# Load the JSON schema with references
schema_file = "values.schema.json"
with open(schema_file, "r") as f:
    json_schema = json.load(f)

# Automatically resolve references
resolved_schema = jsonref.replace_refs(json_schema)

# Extract defaults
defaults = extract_defaults(resolved_schema)


class LiteralDumper(yaml.Dumper):
    def represent_scalar(self, tag, value, style=None):
        # Check if the value contains newlines
        if isinstance(value, str) and "\n" in value:
            style = "|"
        return super().represent_scalar(tag, value, style)


# Save to YAML
output_file = "values.yaml"
with open(output_file, "w") as f:
    f.write("# This file is auto-generated from the values.schema.json file.\n")
    f.write("# The file is also used to generate the GitHub Pages documentation.\n")
    f.write("# Schema JSON files allow defining restrictions, enums and references.\n")
    f.write(f"# Use script {sys.argv[0]} to generate this file.\n")
    yaml.dump(
        defaults,
        f,
        Dumper=LiteralDumper,
        default_flow_style=False,
        allow_unicode=True,
        indent=2,
    )

if some_defaults_not_found:
    print(f"Some default values were not found in {schema_file}. Check the output for warnings.")
    sys.exit(1)
else:
    print(f"Defaults extracted from {schema_file} and saved to {output_file}.")
