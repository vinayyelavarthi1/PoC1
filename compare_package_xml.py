#!/usr/bin/env python3

import argparse
import os
import csv
import xml.etree.ElementTree as ET
import xml.dom.minidom as minidom
from collections import defaultdict

NAMESPACE = "http://soap.sforce.com/2006/04/metadata"


def parse_package_xml(file_path):
    tree = ET.parse(file_path)
    root = tree.getroot()

    data = defaultdict(set)
    version = "60.0"

    for types in root.findall(f'{{{NAMESPACE}}}types'):
        name = types.find(f'{{{NAMESPACE}}}name').text

        for member in types.findall(f'{{{NAMESPACE}}}members'):
            data[name].add(member.text)

    version_node = root.find(f'{{{NAMESPACE}}}version')
    if version_node is not None:
        version = version_node.text

    return dict(data), version


def compare_packages(stage, prod):
    stage_only = defaultdict(set)
    prod_only = defaultdict(set)
    common = defaultdict(set)

    all_types = set(stage.keys()).union(prod.keys())

    for md_type in all_types:
        stage_members = stage.get(md_type, set())
        prod_members = prod.get(md_type, set())

        stage_only[md_type] = stage_members - prod_members
        prod_only[md_type] = prod_members - stage_members
        common[md_type] = stage_members.intersection(prod_members)

    return stage_only, prod_only, common


def generate_package_xml(data, output_file, version):

    package = ET.Element("Package")
    package.set("xmlns", NAMESPACE)

    for md_type in sorted(data.keys()):
        members = sorted(data[md_type])

        if not members:
            continue

        types = ET.SubElement(package, "types")

        for member in members:
            member_el = ET.SubElement(types, "members")
            member_el.text = member

        name = ET.SubElement(types, "name")
        name.text = md_type

    version_el = ET.SubElement(package, "version")
    version_el.text = version

    rough = ET.tostring(package, 'utf-8')
    reparsed = minidom.parseString(rough)

    pretty = reparsed.toprettyxml(indent="    ")

    pretty = "\n".join(
        [line for line in pretty.split("\n") if line.strip()]
    )

    with open(output_file, "w") as f:
        f.write(pretty)


def generate_summary(stage_only, prod_only, output_file):

    with open(output_file, "w") as f:

        f.write("Salesforce Package Comparison Summary\n")
        f.write("====================================\n\n")

        all_types = set(stage_only.keys()).union(prod_only.keys())

        for md_type in sorted(all_types):

            stage = stage_only.get(md_type, [])
            prod = prod_only.get(md_type, [])

            if not stage and not prod:
                continue

            f.write(f"Metadata Type : {md_type}\n")

            if stage:
                f.write("  Stage Only:\n")
                for s in sorted(stage):
                    f.write(f"    - {s}\n")

            if prod:
                f.write("  Production Only:\n")
                for p in sorted(prod):
                    f.write(f"    - {p}\n")

            f.write("\n")


def generate_csv(stage_only, prod_only, common, output):

    with open(output, "w", newline="") as file:

        writer = csv.writer(file)
        writer.writerow(["MetadataType", "Component", "Status"])

        for md_type in sorted(common.keys()):
            for c in sorted(common[md_type]):
                writer.writerow([md_type, c, "Common"])

        for md_type in sorted(stage_only.keys()):
            for s in sorted(stage_only[md_type]):
                writer.writerow([md_type, s, "Stage Only"])

        for md_type in sorted(prod_only.keys()):
            for p in sorted(prod_only[md_type]):
                writer.writerow([md_type, p, "Production Only"])


def main():

    parser = argparse.ArgumentParser()

    parser.add_argument("--stage", required=True)
    parser.add_argument("--prod", required=True)
    parser.add_argument("--outdir", default="output")

    args = parser.parse_args()

    os.makedirs(args.outdir, exist_ok=True)

    stage_data, stage_version = parse_package_xml(args.stage)
    prod_data, prod_version = parse_package_xml(args.prod)

    stage_only, prod_only, common = compare_packages(stage_data, prod_data)

    version = stage_version if stage_version else prod_version

    generate_package_xml(
        stage_only,
        os.path.join(args.outdir, "stage_only_package.xml"),
        version
    )

    generate_package_xml(
        prod_only,
        os.path.join(args.outdir, "production_only_package.xml"),
        version
    )

    generate_summary(
        stage_only,
        prod_only,
        os.path.join(args.outdir, "comparison_summary.txt")
    )

    generate_csv(
        stage_only,
        prod_only,
        common,
        os.path.join(args.outdir, "comparison_details.csv")
    )

    print("Comparison Completed")
    print("Files Generated:")
    print("stage_only_package.xml")
    print("production_only_package.xml")
    print("comparison_summary.txt")
    print("comparison_details.csv")


if __name__ == "__main__":
    main()