# GO analysis

#` Run GO-term enrichment analysis
#`
#` expressiondata must be a data frame with columns corresponding to
#` expression patterns and rows corresponding to genes or transcripts.
#` Both rows and columns must be named. Row names must match the format
#` used in the mappingfile.
#`
#` mappingsfile must be the path to a file containing gene/transcript name
#` -> GO ID mappings.
#`
#` ppcutoff is the cutoff for posterior probability of being associated
#` with each pattern, used to filter out non-significant rows.
#`
#` alpha is the p-value cutoff to use in the Fisher's exact test.
ontology_enrichment <- function(de_data,
                                mappingsfile,
                                conditions,
                                named_patterns=list(),
                                ppcutoff=0.95,
                                alpha=0.05) {
  wd <- getwd()
  dir.create('functional_analysis', showWarnings=FALSE)
  setwd('./functional_analysis')
  for (d in c('results', 'graphs', 'plots')) {
    dir.create(d, showWarnings=FALSE)
  }

  go_output <- perform_GO_enrichment(de_data,
                        mappingsfile,
                        conditions,
                        ppcutoff,
                        alpha)
  go_results <- go_output[['results']]
  go_genes <- go_output[['genes']]
  # replace named patterns
  print('replacing pattern names..')
  go_results$Pattern <- replace_patterns(go_results$Pattern, named_patterns)
  # preserve input order of pattern names
  unnamed_patterns <- setdiff(unique(de_data[['final']]$pattern), named_patterns)
  pattern_levels <- c(named_patterns, unnamed_patterns)
  go_results$Pattern <- factor(go_results$Pattern, levels=pattern_levels, ordered=TRUE)
  go_output[['results']] <- go_results
  # make plots
  setwd('./plots')
  plot_high_level_GO(go_output, de_data)
  plot_detailed_GO(go_output, de_data)
  setwd(wd)
}

#' Produce a horizontal stacked barplot showing the
#' proportion of genes in each enriched GO term that
#' fall into each expression pattern
plot_high_level_GO <- function(go_output, de_data, colourset=NULL) {
  wd <- getwd()
  dir.create('by_pattern', showWarnings=FALSE)
  setwd('./by_pattern')
  print("Making high-level GO plots")
  go_results <- go_output[['results']]
  long_go <- go_output[['genes']]
  de_data[['final']] <- merge(de_data[['final']], long_go, by="gene.id")
  colourmap <- get_colourmap(unique(go_results$Pattern), colourset)
  for (pattern in unique(go_results$Pattern)) {
    subset <- go_results[go_results$Pattern == pattern,]
    for (ontname in unique(subset$Ontology)) {
      ontology <- subset[subset$Ontology == ontname,]
      plot_ontology(ontname, ontology, de_data, pattern, colourmap)
    }
  }
  setwd(wd)
}

#' For each enriched GO term produce a plot showing
#' the expression and direction of each gene.
#' Bars are grouped by gene, with one bar per gene per
#' condition, with y equal to the mean normalised expression
#' count.
plot_detailed_GO <- function(go_output,
                             de_data,
                             maxsize = 50,
                             minsize = 2,
                             colourset="Dark2") {
  wd <- getwd()
  dir.create('by_term', showWarnings=FALSE)
  setwd('./by_term')
  get_package("reshape2")
  print("Making detailed GO plots")
  long_go <- go_output[['genes']]
  go_results <- go_output[['results']]
  # merge into expression and DE data
  final <- de_data[['final']]
  if (is.null(final)) stop("df 'final' does not exist")
  final <- merge(final, long_go, by="gene.id")
  # filter GO terms by size
  terms <- subset(go_results, Annotated <= maxsize & Annotated > minsize)$GO.ID
  final <- subset(final, go.id %in% terms)
  # prepare the dataframe
  # melt means and standard errors to one column each
  mean_cols <- de_data[['mean_cols']]
  mean_colnames <- names(final)[mean_cols]
  sem_colnames <- names(final)[mean_cols + 1]
  melted_means <- reshape2:::melt.data.frame(final[,c('gene.id', mean_colnames)],
                       id='gene.id', variable.name="sample",
                       value.name="mean")
  melted_means$sample <- gsub(melted_means$sample,
                              pattern="\\.mean",
                              replacement="")
  melted_sems <- reshape2:::melt.data.frame(final[,c('gene.id', sem_colnames)],
                       id='gene.id', variable.name="sample",
                       value.name="sem")
  melted_sems$sample <- gsub(melted_sems$sample,
                             pattern="\\.stderr",
                             replacement="")
  melted_means_sems <- merge(melted_means, melted_sems,
                             by=c('gene.id', 'sample'))
  # merge the annotation back in
  data <- merge(melted_means_sems,
                final[,c('gene.id', 'pattern',
                         'go.id', 'Description',
                         'Ontology')],
                by='gene.id')
  data <- merge(data, go_results[,c('GO.ID', 'Term')], by.x='go.id', by.y='GO.ID')
  data <- unique(data)
  # copy pattern ordering from go_results
  # TODO: structure patterns of de_results[['final']] properly
  data$pattern <- factor(data$pattern, levels=levels(go_results$Pattern), ordered=TRUE)
  # tidy up pattern names
  newlevels <- gsub(levels(data$pattern), pattern="_", replacement=" ")
  newlevels <- gsub('(.{1,15})(\\s|$)', '\\1\n', newlevels) # split levels at 15 chars
  levels(data$pattern) <- newlevels
  # generate consistent colour scale
  data$sample <- as.factor(data$sample)
  colourmap <- get_colourmap(levels(data$sample), colourset)
  print(colourmap)
  # plot
  for(term in terms) {
    if (term == "NA" || is.na(term)) {
      stop("GO term is NA")
    }
    plotdata <- subset(data, go.id == term)
    plotdata$Ontology <- as.character(plotdata$Ontology)
    plotdata$go.id <- as.character(plotdata$go.id)
    title <- paste(as.character(plotdata[1,c('Ontology', 'Term', 'go.id')]),
                   collapse="-")
    plot_term(term, plotdata, title, colourmap)
  }
  setwd(wd)
}

#' Generate a colourmap (named vector) mapping pattern names
#' By default, if the set of patterns has length < 8,
#' uses the colourblind optimised palette from
#' http://jfly.iam.u-tokyo.ac.jp/color/ with the yellow moved to end
#' and grey removed. If > 8, use RColorbrewer. Set name corresponds
#' to RColorBrewer sets.
get_colourmap <- function(patterns, set=NULL) {
  if (is.null(set) && length(patterns) < 8) {
    colours <- c("#CC79A7", "#56B4E9", "#009E73", "#E69F00",
                "#0072B2", "#D55E00", "#F0E442")
    colours <- colours[1:length(patterns)]
  } else {
    get_package("RColorBrewer")
    if (is.null(set)) {
      set <- "Set1"
    }
    colours <- brewer.pal(length(patterns), set)
  }
  names(colours) <- patterns
  return(colours)
}

#' Produce a plot showing the expression and direction of each gene
#' in the specified GO term.
#'
#' If there are two conditions, a horizontal barplot is produced,
#' with log2 fold change on the x-axis, genes on the y-axis, and
#' one gene per line.
#'
#' If there are >2 conditions, a grid of barplots is produced,
#' with one barplot per gene, one bar per condition, and the y-axis
#' within each barplot being log expression count.
plot_term <- function(term, d, title,
                      colourmap, save=TRUE) {
  if(title == "NA-NA-NA") {
    # this works around a weird bug where an all-NA title appears
    # seemingly out of nowhere.
    # TODO: figure out where the bug comes from
    return()
  }
  get_package("ggplot2")
  get_package("grid")
  print(paste("Plotting", title, "GO term"))
  d$gene <- paste(d$Description, " (", d$gene.id, ")", sep="") # add locus IDs to gene names
  d$gene <- gsub('(.{1,25})(\\s|$)', '\\1\n', d$gene) # split lines at 25 chars
  p <- ggplot(arrange(d, pattern), aes(x=reorder(factor(gene), mean, FUN=gap),
                                       y=mean,
                                       fill=sample)) +
    geom_bar(stat="identity", position=position_dodge(0.9)) +
    geom_errorbar(aes(ymin=mean-sem, ymax=mean+sem),
                  colour="black", position=position_dodge(0.9),
                  width=0.2) +
    scale_fill_manual(
      values=colourmap,
      guide=guide_legend(
        direction="horizontal",
        label.theme = element_text(angle = 90, face="italic"),
        title.theme = element_text(angle = 90, face="bold"),
        title.hjust = 0.5,
        label.position="top",
        label.hjust = 0.5,
        label.vjust = 0.5
      )
    ) +
    theme_bw() +
    theme(plot.margin = unit(c(1,1,1,1), "cm"), # top, right, bottom, left
          legend.text.align = 0, # left align
          axis.title.x = element_text(angle=180),
          axis.text.x = element_text(angle=90, hjust=1,
                                     vjust=0.5),
          axis.text.y = element_text(angle=90, hjust=0.5)) +
    facet_grid(.~pattern, scales="free_x", space="free_x") +
    xlab("gene description (locus ID)") +
    ylab("mean normalised count")
  if (save) {
    title <- gsub(x=title, pattern="'", replacement="")
    title <- gsub(x=title, pattern=" ", replacement="_")
    title <- gsub(x=title, pattern="/", replacement="-")
    filename <- paste(title, "pdf", sep=".")
    pdf(
      filename,
      width=max(dim(d)[1]*0.5, 7),
      height=7
    )
    print(p)
    dev.off()
    rotate_PDF(filename)
  }
  return(p)
}


#' Produce a plot with all enriched GO terms and the prop of each pattern
plot_ontology <- function(ontname, go_results, de_data, pattern,
                          colourmap, save=TRUE) {
  print(paste("Plotting", ontname, "ontology for pattern:", pattern))
  get_package('ggplot2')
  # extract data from de_data
  final <- de_data[['final']]
  mean_cols <- de_data[['mean_cols']]
  # subset to this ontology
  d <- final[final$Ontology == ontname,]
  # subset to enriched go terms
  d <- d[d$go.id %in% go_results$GO.ID,]
  # count each pattern per GOid
  d <- ddply(d, .(pattern, go.id), summarise, freq=length(unique(gene.id)))
  # convert to percentages, count totals
  d <- ddply(d, .(go.id), function(x) {
    total <- sum(x$freq)
    data.frame(x, prop = x$freq / total, total)
  })
  # add descriptions
  d <- merge(d,
             data.frame(go.id=go_results$GO.ID,
                        description=go_results$Term),
             by='go.id')
  # order
  d$pattern <- factor(d$pattern, levels=levels(go_results$Pattern), ordered=TRUE)
  d$description <- paste(d$description, "\n", d$go.id, " (", d$total, ")", sep="")
  d <- d[with(d, order(-total, pattern)),]
  d <- transform(d, description = reorder(description, -total))
  p <- ggplot(data=d, aes(x=description, y=prop, fill=pattern)) +
    geom_bar(stat='identity') +
    theme_bw() +
    theme(legend.text.align = 0) + # left align
    theme(panel.border = theme_border()) +
    theme(axis.ticks.y=element_blank()) +
    scale_y_continuous(name="Proportion of genes differentially expressed",
                       expand = c(0, 0)) +
    scale_x_discrete(name="GO annotation (count of genes)",
                     expand=c(0, 0)) +
    scale_fill_manual(values=colourmap, name="Enriched in") +
    coord_flip()
  if(save) {
    height = (3*dim(d)[1])+60
    width = 300
    units = "mm"
    ggsave(paste(pattern, "_", ontname, '_GO_enrichment.png', sep=''),
           width=width,
           height=height,
           units=units,
           limitsize=FALSE)
    ggsave(paste(pattern, "_", ontname, "_GO_enrichment.pdf", sep=''),
           width=width,
           height=height,
           units=units,
           limitsize=FALSE)
  }
  return(p)
}

.pt <- 1 / 0.352777778

len0_null <- function(x) {
  if (length(x) == 0)  NULL
  else                 x
}

theme_border <- function(
  type = c("left", "right", "bottom", "top", "none"),
  colour = "black", size = 1, linetype = 1) {
  # use with e.g.: ggplot(...) + opts( panel.border=theme_border(type=c("bottom","left")) ) + ...
  type <- match.arg(type, several.ok=TRUE)
  structure(
    list(type = type, colour = colour, size = size, linetype = linetype),
    class = c("theme_border", "element_blank", "element")
  )
}

element_grob.theme_border <- function(
  element, x = 0, y = 0, width = 1, height = 1,
  type = NULL,
  colour = NULL, size = NULL, linetype = NULL,
  ...) {
  if (is.null(type)) type = element$type
  xlist <- c()
  ylist <- c()
  idlist <- c()
  if ("bottom" %in% type) { # bottom
    xlist <- append(xlist, c(x, x+width))
    ylist <- append(ylist, c(y, y))
    idlist <- append(idlist, c(1,1))
  }
  if ("top" %in% type) { # top
    xlist <- append(xlist, c(x, x+width))
    ylist <- append(ylist, c(y+height, y+height))
    idlist <- append(idlist, c(2,2))
  }
  if ("left" %in% type) { # left
    xlist <- append(xlist, c(x, x))
    ylist <- append(ylist, c(y, y+height))
    idlist <- append(idlist, c(3,3))
  }
  if ("right" %in% type) { # right
    xlist <- append(xlist, c(x+width, x+width))
    ylist <- append(ylist, c(y, y+height))
    idlist <- append(idlist, c(4,4))
  }
  if (length(type)==0 || "none" %in% type) { # blank; cannot pass absence of coordinates, so pass a single point and use an invisible line
    xlist <- c(x,x)
    ylist <- c(y,y)
    idlist <- c(5,5)
    linetype <- "blank"
  }
  gp <- gpar(lwd = len0_null(size * .pt), col = colour, lty = linetype)
  element_gp <- gpar(lwd = len0_null(element$size * .pt), col = element$colour, lty = element$linetype)
  polylineGrob(
    x = xlist, y = ylist, id = idlist, ..., default.units = "npc",
    gp = modifyList(element_gp, gp),
  )
}

perform_GO_enrichment <- function(de_data,
                                mappingsfile,
                                conditions,
                                ppcutoff=0.95,
                                alpha=0.05) {
  print("Performing GO enrichment tests")
  final <- de_data[['final']]
  if (length(unique(conditions)) == 2) {
    prob_cols <- which(names(final)=='PPDE')
  } else {
    prob_cols <- de_data[['prob_cols']]
  }

  get_package('topGO', bioconductor=TRUE)
  geneID2GO <- readMappings(file = mappingsfile)
  geneID2GO <- geneID2GO[names(geneID2GO) %in% final$gene.id]
  results = data.frame()
  genes = list()
  # iterate through patterns performing GO analysis
  for (pattern in unique(final$pattern)) {
    print(paste("GO enrichment testing for pattern:", pattern))

    allgenes <- 1:dim(final)[1]
    names(allgenes) <- final$gene.id
    topDiffGenes <- function(row) {
      return(final$pattern[row] == pattern)
    }
    ontologies <- c('BP', 'MF', 'CC')
    # iterate through ontologies testing each separately
    for (ontology in ontologies) {
      print(paste("Fisher testing GO enrichment for ontology", ontology, "in condition:", pattern))
      GOdata <- new("topGOdata",
                    description = "Test", ontology = ontology,
                    allGenes = allgenes, geneSel = topDiffGenes,
                    annot = annFUN.gene2GO, gene2GO = geneID2GO)

      # run weighted (mix of elim and weight algorithms) fisher test
      result <- runTest(GOdata, 'weight01', 'fisher')
      allRes <- GenTable(GOdata, weightedFisher = result,
                         orderBy = "weightedFisher", ranksOf = "weightedFisher",
                         topNodes = 100, useLevels=TRUE)

      allRes <- allRes[allRes$weightedFisher <= alpha,]

      # TODO: this always gives incorrect numbers in the Annotated column
      # need to investigate whether topGO is doing this wrongly
      if (!is.null(allRes) && nrow(allRes) > 0) {
        go.ids <- allRes$GO.ID
        res.genes <- genesInTerm(GOdata, go.ids)
        genes <- c(genes, res.genes)
        print(paste(nrow(allRes), "significantly enriched GO terms found"))
        write.table(file=paste(paste("results", ontology, sep="/"), pattern, "GO.csv", sep='_'),
                    x=allRes,
                    row.names=F,
                    col.names=T,
                    sep=",")

        # print graph of signficant nodes
        printGraph(GOdata, result,
                   firstSigNodes = 15,
                   fn.prefix = paste(paste("graphs", ontology, sep="/"), pattern, sep='_'),
                   useInfo = "all",
                   pdfSW = TRUE)
        # save ontology and pattern
        allRes$Ontology <- ontology
        allRes$Pattern <- pattern
        results <- rbind(results, allRes)
      }
    }
  }
  genes <- go_genes_to_long_go(genes)
  return(list(results=results, genes=genes))
}

#' Return the difference between the minimum
#' and maximum values in the input
gap <- function(v) {
  return(max(v) - min(v))
}

#' Rotate all PDFs in the current directory
#' using pdftk, only if this is a Linux system
#' and pdftk is installed
rotate_PDF <- function(file) {
  if (Sys.info()['sysname'] != "Windows") {
    outfile <- gsub(file, pattern="\\.pdf", replacement="_v\\.pdf")
    system(paste("pdftk \"", file, "\" cat 1east output \"", outfile, "\"", sep=""))
    unlink(file)
  }
}

go_genes_to_long_go <- function(go_genes) {
  df <- data.frame()
  for (go.id in names(go_genes)) {
    df <- rbind(df, data.frame(gene.id=go_genes[[go.id]], go.id=go.id))
  }
  genes <- data.frame()
  onts <- list(BP=GOBPTerm, MF=GOMFTerm, CC=GOCCTerm)
  for (ontname in names(onts)) {
    ont <- onts[[ontname]]
    term <- ls(ont)
    if (sum(df$go.id %in% term) > 0) {
      genes <- rbind(genes, data.frame(df[df$go.id %in% term,], Ontology=ontname))
    }
  }
  print(dim(genes))
  return(genes)
}
