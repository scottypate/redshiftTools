#' Append redshift table
#'
#' Upload a table to S3 and then append it to a Redshift Table.
#' The table on redshift has to have the same structure and column ordering to work correctly.
#'
#' @param df a data frame
#' @param dbcon an RPostgres/RJDBC connection to the redshift server
#' @param table_name the name of the table to replace
#' @param split_files optional parameter to specify amount of files to split into. If not specified will look at amount of slices in Redshift to determine an optimal amount.
#' @param bucket the name of the temporary bucket to load the data. Will look for AWS_BUCKET_NAME on environment if not specified.
#' @param region the region of the bucket. Will look for AWS_DEFAULT_REGION on environment if not specified.
#' @param iam_role_arn an iam role arn with permissions fot the bucket. Will look for AWS_IAM_ROLE_ARN on environment if not specified. This is ignoring access_key and secret_key if set.
#' @param wlm_slots amount of WLM slots to use for this bulk load http://docs.aws.amazon.com/redshift/latest/dg/tutorial-configuring-workload-management.html
#' @param additional_params Additional params to send to the COPY statement in Redshift
#'
#' @examples
#' library(DBI)
#'
#' a=data.frame(a=seq(1,10000), b=seq(10000,1))
#'
#'\dontrun{
#' con <- dbConnect(RPostgres::Postgres(), dbname="dbname",
#' host='my-redshift-url.amazon.com', port='5439',
#' user='myuser', password='mypassword',sslmode='require')
#'
#' rs_append_table(df=a, dbcon=con, table_name='testTable',
#' bucket="my-bucket", split_files=4)
#'
#' }
#' @export
rs_append_table = function(
    df,
    dbcon,
    table_name,
    split_files,
    bucket=Sys.getenv('AWS_BUCKET_NAME'),
    region=Sys.getenv('AWS_DEFAULT_REGION'),
    iam_role_arn=Sys.getenv('AWS_IAM_ROLE_ARN'),
    wlm_slots=1,
    additional_params=''
    )
  {

  message('Initiating Redshift table append for table ',table_name)

  if(!inherits(df, 'data.frame')){
    warning("The df parameter must be a data.frame or an object compatible with it's interface")
    return(FALSE)
  }
  numRows = nrow(df)
  numCols = ncol(df)

  if(numRows == 0){
    warning("Empty dataset provided, will not try uploading")
    return(FALSE)
  }

  message(paste0("The provided data.frame has ", numRows, ' rows and ', numCols, ' columns'))


  if(missing(split_files)){
    split_files = splitDetermine(dbcon, numRows, as.numeric(object.size(df[1,])))
  }
  split_files = pmin(split_files, numRows)

  # Upload data to S3
  prefix = uploadToS3(df, bucket, split_files, region)

  if(wlm_slots>1){
    queryStmt(dbcon,paste0("set wlm_query_slot_count to ", wlm_slots));
  }

  result = tryCatch({
      stageTable=s3ToRedshift(dbcon, table_name, bucket, prefix, region, iam_role_arn, additional_params)

      # Use a single transaction
      queryStmt(dbcon, 'begin')

      message("Insert new rows")
      queryStmt(dbcon, sprintf('insert into %s select * from %s', table_name, stageTable))

      message("Drop staging table")
      queryStmt(dbcon, sprintf("drop table %s", stageTable))

      message("Committing changes")
      queryStmt(dbcon, "COMMIT;")

      return(TRUE)
  }, error = function(e) {
      warning(e$message)
      queryStmt(dbcon, 'ROLLBACK;')
      return(FALSE)
  }, finally = {
    message("Deleting temporary files from S3 bucket")
    deletePrefix(prefix, bucket, split_files, region)
  })

  return (result)
}
