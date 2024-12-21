import json
import pandas as pd
import argparse
import jsonref


# Flatten JSON properties
def flatten_properties(properties, parent_key=""):
    """
    Flatten the properties of a JSON schema into a list of dictionaries
    containing the field path, type, description, and default values.
    """
    items = []

    for key, value in properties.items():
        field_path = f"{parent_key}.{key}" if parent_key else key
        # Check if enum is present (instead of type)
        if "enum" in value:
            value["enum"] = [f'null' if not x else x for x in value["enum"]]
            field_type = f"enum: [{', '.join(value['enum'])}]"
        else:
            field_type = value.get("type", "")
        description = value.get("description", "")
        default = value.get("default", "")

        # Add the current property
        items.append(
            {
                "Field Path": field_path,
                "Type": field_type,
                "Description": description,
                "Default": default,
            }
        )

        # If this property has nested properties, recurse into them
        if "properties" in value:
            nested_items = flatten_properties(value["properties"], field_path)
            items.extend(nested_items)

    return items


# Set up argument parser
parser = argparse.ArgumentParser(
    description="Generate a Markdown table from a JSON schema file."
)
parser.add_argument(
    "--output", type=str, required=True, help="Path to the output Markdown file."
)
args = parser.parse_args()

# Load values.schema.json
with open("values.schema.json", "r") as f:
    schema = json.load(f)

# Automatically resolve references
resolved_schema = jsonref.replace_refs(schema)

# Get the flattened properties
properties = resolved_schema.get("properties", {})
flattened_properties = flatten_properties(properties)

# Convert to a DataFrame for easier Markdown generation
df = pd.DataFrame(flattened_properties)

# Sort the DataFrame by 'Field Path'
df = df.sort_values(["Field Path"])

# Generate Markdown table
markdown_table = df.to_markdown(index=False)

# Save the Markdown table to a file
with open(args.output, "w") as f:
    f.write(markdown_table)

print(f"Markdown table generated and saved to '{args.output}'.")
