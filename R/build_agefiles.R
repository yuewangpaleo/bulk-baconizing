build_agefiles <- function(param, datasets, downloads, ageorder = NULL, settings, topdepth, botdepth, verbose = TRUE) {
  
  if(!(is.na(param$suitable)) & 
     param$suitable == 1 & 
     file.exists(paste0('Cores/', param$handle, '/', param$handle, '.csv')) &
     file.exists(paste0('Cores/', param$handle, '/', param$handle, '_depths.txt'))) {
    if(verbose == TRUE) {
      message('Bacon core and depths files have already been written.  Set `suitable` to NA to rewrite files.')
    }
    return(param)
  }
  
  if (is.null(ageorder)) {
    ageorder <- get_table('agetypes')
  }
  
  url <- paste0('http://api-dev.neotomadb.org/v2.0/data/datasets/', param$datasetid, '/chronology')
  chrons <- jsonlite::fromJSON(url, simplifyVector=FALSE)$data[[1]]
  
  modeldefault <- chrons$chronologies %>%
    purrr::map(function (x) {
      data.frame(agetype = x$agetype,
                 default = x$isdefault,
                 stringsAsFactors = FALSE) }) %>%
    bind_rows()
  
  modeldefault$order <- ageorder$Precedence[match(modeldefault$agetype, ageorder$AgeType)]
  
  if (sum(modeldefault$order == min(modeldefault$order) & modeldefault$default) == 1) {
    # This is the case that everything is good.
    # The precendene is the lowest and it has only one defined default for that low model.
  } else {
    if (sum(modeldefault$order == min(modeldefault$order) & modeldefault$default) > 1) {
      # There are multiple default models in the best age class:
      
      message('There are multiple default models defined for the "best" age type.')
      
      most_recent <- sapply(chrons$chronologies, function(x) {
        ifelse(is.null(x$dateprepared), 0, lubridate::as_date(x$dateprepared))
      })
      
      new_default <- most_recent == max(most_recent) &
        modeldefault$default &
        modeldefault$order == min(modeldefault$order)
      
      if (sum(new_default) == 1) {
        # Date of model preparation differs:
        param$notes <- add_msg(param$notes, 'There are multiple default models defined for the best age type: Default assigned to most recent model')
        modeldefault$default <- new_default
      } else {
        # Date is the same, differentiate by chronology ID:
        chronid <- sapply(chrons$chronologies, function(x) x$chronologyid)
        
        modeldefault$default <- new_default & chronid == max(chronid)
        
        param$notes <- add_msg(param$notes, 'There are multiple default models defined for the best age type: Default assigned to most model with highest chronologyid')
      }
    } else {
      # Here there is no default defined:
      if (sum(modeldefault$order == min(modeldefault$order)) == 1) {
        # No default defined, but only one best age scale:
        modeldefault$default <- modeldefault$order == min(modeldefault$order)
        param$notes <- add_msg(param$notes, 'There are no default models defined for the best age type: Default assigned to best age-type by precedence.')
      } else {
        # There is no default and multple age models for the "best" type:
        most_recent <- sapply(chrons$chronologies, function(x) {
          ifelse(is.null(x$dateprepared), 0, lubridate::as_date(x$dateprepared))})
        
        new_default <- most_recent == max(most_recent) &
          modeldefault$order == min(modeldefault$order)
        
        if (sum(new_default) == 1) {
          modeldefault$default <- new_default
          param$notes <- add_msg(param$notes, 'There are no default models defined for the best age type: Most recently generated model chosen')
        } else {
          
          # You are the default if you have the highest chronology id.
          chronid <- sapply(chrons$chronologies, function(x) x$chronologyid)
          
          new_default <- most_recent == max(most_recent) &
            modeldefault$order == min(modeldefault$order) &
            chronid == max(chronid)
          
          modeldefault$default <- new_default
          param$notes <- add_msg(param$notes, 'There are no default models defined for the best age type: Age models have same preparation date.  Model with highest chron ID was selected')
        }
      }
    }
  }
  
  good_row <- (1:nrow(modeldefault))[modeldefault$order == min(modeldefault$order) & modeldefault$default]
  
  param$age.type <- modeldefault$agetype[good_row]
  
  did_char <- as.character(param$datasetid)
  
  handle <- datasets[[did_char]]$dataset.meta$collection.handle
  depth <- data.frame(depths = downloads[[did_char]]$sample.meta$depth)
  depth <- subset(depth, depths >= topdepth & depths <= botdepth)
  ages <- data.frame(ages = downloads[[did_char]]$sample.meta$age)
  
  agetypes <- sapply(chrons[[2]], function(x) x$agetype)
  
  ## Here we check to see if we're dealing with varved data:
  
  if ('Varve years BP' %in% agetypes) {
    
    if (length(list.files(settings$core_path)) == 0 | !handle %in% list.files(settings$core_path)) {
      works <- dir.create(path = paste0(settings$core_path, '/', handle))
      assertthat::assert_that(works, msg = 'Could not create the directory.')
    }
    
    if (all(depths == ages)) {
      ## It's not clear what's happening here, but we identify the records for further
      #  investigation.
      ages <- data.frame( labid = "Annual laminations",
                          age = ages,
                          error = 0,
                          depth = depths,
                          cc = 0,
                          stringsAsFactors = FALSE)
      if (verbose == TRUE) {
        message('Annual laminations defined in the age models.')
      }
      
      param$notes <- add_msg(param$notes, 'Annual laminations defined in the age models.')
      param$suitable <- 1
      
      readr::write_csv(x = ages, path = paste0('Cores/', handle, '/', handle, '.csv'), col_names = TRUE)
      readr::write_csv(x = depths, path = paste0('Cores/', handle, '/', handle, '_depths.txt'), col_names = FALSE)
      
    } else {
      
      if (verbose == TRUE) {
        message('Annual laminations defined in the age models but ages and depths not aligned.')
      }
      param$notes <- add_msg(param$notes, 'Annual laminations defined as an age model but ages and depths not aligned.')
      param$suitable <- 0
    }
    
  } else {
    out <- try(make_coredf(chrons[[2]][[good_row]],
                           core_param = param,
                           settings = settings))
    
    if (!'try-error' %in% class(out)) {
      ages <- out[[1]]
      param <- out[[2]]
      
      param$ndates <- nrow(ages)
      
      if (file.exists(paste0('Cores/', handle, '/', handle, '.csv'))) {
        param$notes <- add_msg(param$notes, 'Overwrote prior chronology file.')
      }
      
      readr::write_csv(x = ages, path = paste0('Cores/', handle, '/', handle, '.csv'), col_names = TRUE)
      readr::write_csv(x = depth, path = paste0('Cores/', handle, '/', handle, '_depths.txt'), col_names = FALSE)
      
    } else {
      param$notes <- add_msg(param$notes, 'Error processing the age file.')
    }
  }
  return(param)
}