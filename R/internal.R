# Internal utility functions used by the redshift tools

if(getRversion() >= "2.15.1")  utils::globalVariables(c("i", "obj"))

#' @importFrom "aws.s3" "put_object" "bucket_exists"
#' @importFrom "aws.ec2metadata" "is_ec2"
#' @importFrom "utils" "write.csv"
#' @importFrom "purrr" "map2"
#' @importFrom "progress" "progress_bar"
#' @export
uploadToS3 = function(data, bucket, split_files, region){
  is_ec2()
  prefix=paste0(sample(rep(letters, 10),50),collapse = "")
  if(!bucket_exists(bucket, region=region)){
    stop("Bucket does not exist")
  }

  splitted = suppressWarnings(split(data, seq(1:split_files)))

  message(paste("Uploading", split_files, "files with prefix", prefix, "to bucket", bucket))


  pb <- progress_bar$new(total = split_files, format='Uploading file :current/:total [:bar]')
  pb$tick(0)

  upload_part = function(part, i){
    tmpFile = tempfile()
    s3Name=paste(bucket, "/", prefix, ".", formatC(i, width = 4, format = "d", flag = "0"), sep="")
    write.csv(part, gzfile(tmpFile, encoding="UTF-8"), na='', row.names=F, quote=T)

    r=put_object(file = tmpFile, object = s3Name, bucket = "", region=region)
    pb$tick()
    return(r)
  }

  res = map2 (splitted, 1:split_files, upload_part)

  if(length(which(!unlist(res))) > 0){
    warning("Error uploading data!")
    return(NA)
  }else{
    message("Upload to S3 complete!")
    return(prefix)
  }
}

#' @importFrom "aws.s3" "delete_object"
#' @importFrom "aws.ec2metadata" "is_ec2"
#' @importFrom "purrr" "map"
deletePrefix = function(prefix, bucket, split_files, region){
  is_ec2()
  s3Names=paste(prefix, ".", formatC(1:split_files, width = 4, format = "d", flag = "0"), sep="")

  message(paste("Deleting", split_files, "files with prefix", prefix, "from bucket", bucket))

  pb <- progress_bar$new(total = split_files, format='Deleting file :current/:total [:bar]')
  pb$tick(0)

  deleteObj = function(obj){
    delete_object(obj, bucket, region=region)
    pb$tick()
  }

  res = map(s3Names, deleteObj)
}

#' @importFrom DBI dbGetQuery
queryDo = function(dbcon, query){
  dbGetQuery(dbcon, query)
}

#' @importFrom DBI dbExecute
queryStmt = function(dbcon, query){
  if(inherits(dbcon, 'JDBCConnection')){
    RJDBC::dbSendUpdate(dbcon, query)
  }else{
    dbExecute(dbcon, query)
  }
}

splitDetermine = function(dbcon, numRows, rowSize){
  message("Getting number of slices from Redshift")
  slices = queryDo(dbcon,"select count(*) from stv_slices")
  slices_num = pmax(as.integer(round(slices[1,'count'])), 1)
  split_files = slices_num

  bigSplit = pmin(floor((numRows*rowSize)/(256*1024*1024)), 5000) #200Mb Per file Up to 5000 files
  smallSplit = pmax(ceiling((numRows*rowSize)/(10*1024*1024)), 1) #10MB per file, very small files

  if(bigSplit > slices_num){
    split_files=slices_num*round(bigSplit/slices_num) # Round to nearest multiple of slices, optimizes the load
  }else if(smallSplit < slices_num){
    split_files=smallSplit
  }else{
    split_files=slices_num
  }

  message(sprintf("%s slices detected, will split into %s files", slices, split_files))
  return(split_files)
}


s3ToRedshift = function(dbcon, table_name, bucket, prefix, region, iam_role_arn, additional_params){
    stageTable=paste0(sample(letters,16),collapse = "")
    # Create temporary table for staging data
    queryStmt(dbcon, sprintf("create temp table %s (like %s)", stageTable, table_name))
    copyStr = "copy %s from 's3://%s/%s.' region '%s' csv gzip ignoreheader 1 emptyasnull COMPUPDATE FALSE STATUPDATE FALSE %s %s"
    # Use IAM Role if available
    credsStr = sprintf("iam_role '%s'", iam_role_arn)
    statement = sprintf(copyStr, stageTable, bucket, prefix, region, additional_params, credsStr)
    queryStmt(dbcon, statement)

    return(stageTable)
}
