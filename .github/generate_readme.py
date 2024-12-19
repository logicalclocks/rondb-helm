import json
import pandas as pd

# Flatten JSON properties


def flatten_properties(properties, parent_key=""):
    """
    Flatten the properties of a JSON schema into a list of dictionaries
    containing the field path, type, description, and default values.
    """
    items = []

    for key, value in properties.items():
        field_path = f"{parent_key}.{key}" if parent_key else key
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


# Load values.schema.json
with open("values.schema.json", "r") as f:
    schema = json.load(f)

# Get the flattened properties
properties = schema.get("properties", {})
flattened_properties = flatten_properties(properties)

# Convert to a DataFrame for easier Markdown generation
df = pd.DataFrame(flattened_properties)

# Sort the DataFrame by 'Field Path'
df = df.sort_values(["Field Path"])

# Generate Markdown table
markdown_table = df.to_markdown(index=False)

# Save the Markdown table to a file
with open("schema_table.md", "w") as f:
    f.write(markdown_table)

print("Markdown table generated and saved to 'schema_table.md'.")
