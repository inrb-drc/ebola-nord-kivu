rule all:
    input:
        auspice_tree = "auspice/ebola-nord-kivu_tree.json",
        auspice_meta = "auspice/ebola-nord-kivu_meta.json"

rule files:
    params:
        input_fasta = "data/sequences.fasta",
        metadata = "data/metadata.tsv",
        dropped_strains = "config/dropped_strains.txt",
        reference = "config/reference.gb",
        clades = "config/clades.tsv",
        colors = "config/colors.tsv",
        lat_longs = "config/lat_longs.tsv",
        auspice_config = "config/auspice_config.json"

files = rules.files.params

rule filter:
    message:
        """
        Filtering to
          - excluding strains in {input.exclude}
        """
    input:
        sequences = files.input_fasta,
        metadata = files.metadata,
        exclude = files.dropped_strains
    output:
        sequences = "results/filtered.fasta"
    shell:
        """
        augur filter \
            --sequences {input.sequences} \
            --metadata {input.metadata} \
            --exclude {input.exclude} \
            --output {output.sequences} \
        """

rule align:
    message:
        """
        Aligning sequences to {input.reference}
          - filling gaps with N
          - removing reference sequence
        """
    input:
        sequences = rules.filter.output.sequences,
        reference = files.reference
    output:
        alignment = "results/aligned.fasta"
    shell:
        """
        augur align \
            --sequences {input.sequences} \
            --reference-sequence {input.reference} \
            --output {output.alignment} \
            --fill-gaps \
            --remove-reference
        """

rule tree:
    message: "Building tree"
    input:
        alignment = rules.align.output.alignment
    output:
        tree = "results/tree_raw.nwk"
    shell:
        """
        augur tree \
            --alignment {input.alignment} \
            --output {output.tree}
        """

rule refine:
    message:
        """
        Refining tree
          - estimate timetree
          - use {params.coalescent} coalescent timescale
          - estimate {params.date_inference} node dates
        """
    input:
        tree = rules.tree.output.tree,
        alignment = rules.align.output,
        metadata = files.metadata
    output:
        tree = "results/tree.nwk",
        node_data = "results/branch_lengths.json"
    params:
        coalescent = "skyline",
        date_inference = "marginal"
    shell:
        """
        augur refine \
            --tree {input.tree} \
            --alignment {input.alignment} \
            --metadata {input.metadata} \
            --output-tree {output.tree} \
            --output-node-data {output.node_data} \
            --timetree \
            --root "outgroup" \
            --coalescent {params.coalescent} \
            --date-confidence \
            --date-inference {params.date_inference}
        """

rule prune_outgroup:
    message: "Pruning the outgroup from the tree"
    input:
        tree = rules.refine.output.tree
    output:
        tree = "results/tree_pruned.nwk"
    run:
        from Bio import Phylo
        T = Phylo.read(input[0], "newick")
        outgroup = [c for c in T.find_clades() if str(c.name) == "outgroup"][0]
        # T.root_with_outgroup(outgroup)
        T.prune(outgroup)
        Phylo.write(T, output[0], "newick")

rule ancestral:
    message: "Reconstructing ancestral sequences and mutations"
    input:
        tree = rules.prune_outgroup.output.tree,
        alignment = rules.align.output
    output:
        node_data = "results/nt_muts.json"
    params:
        inference = "joint"
    shell:
        """
        augur ancestral \
            --tree {input.tree} \
            --alignment {input.alignment} \
            --output {output.node_data} \
            --inference {params.inference}
        """

rule translate:
    message: "Translating amino acid sequences"
    input:
        tree = rules.prune_outgroup.output.tree,
        node_data = rules.ancestral.output.node_data,
        reference = files.reference
    output:
        node_data = "results/aa_muts.json"
    shell:
        """
        augur translate \
            --tree {input.tree} \
            --ancestral-sequences {input.node_data} \
            --reference-sequence {input.reference} \
            --output {output.node_data} \
        """

rule clades:
    input:
        tree = rules.prune_outgroup.output.tree,
        aa_muts = rules.translate.output.node_data,
        nuc_muts = rules.ancestral.output.node_data,
        clades = files.clades
    output:
        clade_data = "results/clades.json"
    shell:
        """
        augur clades --tree {input.tree} \
            --mutations {input.nuc_muts} {input.aa_muts} \
            --clades {input.clades} \
            --output {output.clade_data}
        """

rule traits:
    message: "Inferring ancestral traits for {params.columns!s}"
    input:
        tree = rules.prune_outgroup.output.tree,
        metadata = files.metadata
    output:
        node_data = "results/traits.json",
    params:
        columns = "health_zone"
    shell:
        """
        augur traits \
            --tree {input.tree} \
            --metadata {input.metadata} \
            --output {output.node_data} \
            --columns {params.columns} \
            --confidence
        """

rule export:
    message: "Exporting data files for auspice"
    input:
        tree = rules.prune_outgroup.output.tree,
        metadata = files.metadata,
        branch_lengths = rules.refine.output.node_data,
        traits = rules.traits.output.node_data,
        nt_muts = rules.ancestral.output.node_data,
        aa_muts = rules.translate.output.node_data,
        colors = files.colors,
        lat_longs = files.lat_longs,
        clades = rules.clades.output.clade_data,
        auspice_config = files.auspice_config
    output:
        auspice_tree = rules.all.input.auspice_tree,
        auspice_meta = rules.all.input.auspice_meta
    shell:
        """
        augur export \
            --tree {input.tree} \
            --metadata {input.metadata} \
            --node-data {input.branch_lengths} {input.traits} {input.nt_muts} {input.clades} {input.aa_muts} \
            --colors {input.colors} \
            --lat-longs {input.lat_longs} \
            --auspice-config {input.auspice_config} \
            --output-tree {output.auspice_tree} \
            --output-meta {output.auspice_meta}
        """

rule clean:
    message: "Removing directories: {params}"
    params:
        "results ",
        "auspice"
    shell:
        "rm -rfv {params}"
