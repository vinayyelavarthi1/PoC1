#!/usr/bin/env python3
import argparse
import csv
import os
import xml.etree.ElementTree as ET
from collections import defaultdict

XML_NS = {"md": "http://soap.sforce.com/2006/04/metadata"}
ET.register_namespace("", XML_NS["md"])


def parse_package_xml(file_path):
    """
    Parse Salesforce package.xml and return:
    {
        "types": {
            "ApexClass": {"ClassA", "ClassB"},
            "CustomObject": {"Account_Ext__c"}
        },
        "version": "60.0"
    }
    """
    tree = ET.parse(file_path)
    root = tree.getroot()

    package_data = defaultdict(set)
    version = None

    for types_node in root.findall("md:types", XML_NS):
        name_node = types_node.find("md:name", XML_NS)
        if name_node is None or not name_node.text:
            continue

        metadata_type = name_node.text.strip()

        for member_node in types_node.findall("md:members", XML_NS):
            if member_node.text:
                package_data[metadata_type].add(member_node.text.strip())

    version_node = root.find("md:version", XML_NS)
    if version_node is not None and version_node.text:
        version = version_node.text.strip()

    return {
        "types": dict(package_data),
        "version": version
    }


def compare_packages(stage_pkg, prod_pkg):
    """
    Compare Stage and Production package data.
    Returns:
      - stage_only
      - prod_only
      - common
    """
    stage_types = stage_pkg["types"]
    prod_types = prod_pkg["types"]

    all_metadata_types = sorted(set(stage_types.keys()) | set(prod_types.keys()))

    stage_only = defaultdict(set)
    prod_only = defaultdict(set)
    common = defaultdict(set)

    for md_type in all_metadata_types:
        stage_members = stage_types.get(md_type, set())
        prod_members = prod_types.get(md_type, set())

        stage_only[md_type] = stage_members - prod_members
        prod_only[md_type] = prod_members - stage_members
        common[md_type] = stage_members & prod_members

    return dict(stage_only), dict(prod_only), dict(common)


def build_package_xml(diff_data, output_file, version="60.0"):
    """
    Write a package.xml containing only the differences.
    """
    package_el = ET.Element("{http://soap.sforce.com/2006/04/metadata}Package")

    for md_type in sorted(diff_data.keys()):
        members = sorted(diff_data[md_type])
        if not members:
            continue

        types_el = ET.SubElement(package_el, "{http://soap.sforce.com/2006/04/metadata}types")
        for member in members:
            member_el = ET.SubElement(types_el, "{http://soap.sforce.com/2006/04/metadata}members")
            member_el.text = member

        name_el = ET.SubElement(types_el, "{http://soap.sforce.com/2006/04/metadata}name")
        name_el.text = md_type

    version_el = ET.SubElement(package_el, "{http://soap.sforce.com/2006/04/metadata}version")
    version_el.text = version

    tree = ET.ElementTree(package_el)
    tree.write(output_file, encoding="utf-8", xml_declaration=True)


def write_summary(stage_only, prod_only, common, output_file):
    with open(output_file, "w", encoding="utf-8") as f:
        f.write("Salesforce package.xml Comparison Summary\n")
        f.write("=" * 50 + "\n\n")

        all_types = sorted(set(stage_only.keys()) | set(prod_only.keys()) | set(common.keys()))

        for md_type in all_types:
            s_only = sorted(stage_only.get(md_type, set()))
            p_only = sorted(prod_only.get(md_type, set()))
            both = sorted(common.get(md_type, set()))

            if not s_only and not p_only and not both:
                continue

            f.write(f"Metadata Type: {md_type}\n")
            f.write(f"  Common Count        : {len(both)}\n")
            f.write(f"  Stage Only Count    : {len(s_only)}\n")
            f.write(f"  Production Only Count: {len(p_only)}\n")

            if s_only:
                f.write("  Stage Only Members:\n")
                for item in s_only:
                    f.write(f"    - {item}\n")

            if p_only:
                f.write("  Production Only Members:\n")
                for item in p_only:
                    f.write(f"    - {item}\n")

            f.write("\n")


def write_csv(stage_only, prod_only, common, output_file):
    with open(output_file, "w", newline="", encoding="utf-8") as csvfile:
        writer = csv.writer(csvfile)
        writer.writerow(["MetadataType", "Member", "Status"])

        all_types = sorted(set(stage_only.keys()) | set(prod_only.keys()) | set(common.keys()))

        for md_type in all_types:
            for member in sorted(common.get(md_type, set())):
                writer.writerow([md_type, member, "Common"])

            for member in sorted(stage_only.get(md_type, set())):
                writer.writerow([md_type, member, "Stage Only"])

            for member in sorted(prod_only.get(md_type, set())):
                writer.writerow([md_type, member, "Production Only"])


def normalize_version(stage_version, prod_version):
    """
    Pick a version for output package.xml.
    Preference: higher numeric version if both exist, otherwise whichever exists.
    """
    def safe_float(v):
        try:
            return float(v)
        except (TypeError, ValueError):
            return None

    sv = safe_float(stage_version)
    pv = safe_float(prod_version)

    if sv is not None and pv is not None:
        return str(max(sv, pv))
    return stage_version or prod_version or "60.0"


def main():
    parser = argparse.ArgumentParser(description="Compare two Salesforce package.xml files.")
    parser.add_argument("--stage", required=True, help="Path to Stage package.xml")
    parser.add_argument("--prod", required=True, help="Path to Production package.xml")
    parser.add_argument("--outdir", default="comparison_output", help="Output directory")
    args = parser.parse_args()

    os.makedirs(args.outdir, exist_ok=True)

    stage_pkg = parse_package_xml(args.stage)
    prod_pkg = parse_package_xml(args.prod)

    stage_only, prod_only, common = compare_packages(stage_pkg, prod_pkg)
    out_version = normalize_version(stage_pkg["version"], prod_pkg["version"])

    stage_only_xml = os.path.join(args.outdir, "stage_only_package.xml")
    prod_only_xml = os.path.join(args.outdir, "production_only_package.xml")
    summary_txt = os.path.join(args.outdir, "comparison_summary.txt")
    details_csv = os.path.join(args.outdir, "comparison_details.csv")

    build_package_xml(stage_only, stage_only_xml, out_version)
    build_package_xml(prod_only, prod_only_xml, out_version)
    write_summary(stage_only, prod_only, common, summary_txt)
    write_csv(stage_only, prod_only, common, details_csv)

    print("Comparison completed successfully.")
    print(f"Generated files:")
    print(f"  - {stage_only_xml}")
    print(f"  - {prod_only_xml}")
    print(f"  - {summary_txt}")
    print(f"  - {details_csv}")


if __name__ == "__main__":
    main()