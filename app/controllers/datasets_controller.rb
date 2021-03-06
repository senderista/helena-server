class DatasetsController < ApplicationController

	require 'csv'

	skip_before_action :protect_from_forgery, :only =>[:new] # save_relation is going to be coming from the Chrome extension, so can't get the CSRF token.  in future should consider whether we should require some kind of authentication for this
	protect_from_forgery with: :null_session, :only =>[:new]

  def new
        dataset = Dataset.create(params.permit(:program_id, :name))
  	render json: { id: dataset.id }
  end

  module Scraped
    TEXT = 1
    LINK = 2
  end

  def save_slice
    Dataset.save_slice_internals(params)
  	render json: { }
  end

  def updatedataset
    dataset = Dataset.find(params[:id])
    dataset.name = params[:name]
    dataset.program_id = params[:program_id]
    dataset.save

    render json: {}
  end

  def programfordataset
    dataset = Dataset.find(params[:id])
    prog_id = dataset.program_id
    render json: {program_id: prog_id}
  end

  def gen_filename(dataset)
      fn = dataset.name
      if (fn == nil or fn == "")
          fn = "dataset"
      end
      fn = fn + "_" + dataset.id.to_s
      return fn
  end

#-------------------------

  def download()
    dataset = Dataset.find(params[:id])
    filename = gen_filename(dataset)
    respond_to do |format|
      format.csv render_csv(dataset, filename)
    end
  end

  def render_csv(dataset, filename)
    set_file_headers(filename)
    set_streaming_headers()

    response.status = 200

    #setting the body to an enumerator, rails will iterate this enumerator
    self.response_body = csv_lines(dataset)
  end

  def set_file_headers(file_name)
    headers["Content-Type"] = "text/csv"
    headers["Content-disposition"] = "attachment; filename=\"#{file_name}\""
  end

  def set_streaming_headers()
    #nginx doc: Setting this to "no" will allow unbuffered responses suitable for Comet and HTTP streaming applications
    headers['X-Accel-Buffering'] = 'no'
    headers["Cache-Control"] ||= "no-cache"
    headers.delete("Content-Length")
  end

  def csv_lines(dataset)
    Enumerator.new do |output|
      Dataset.batch_based_construction(dataset){ |row| 
        output << CSV.generate_line(row) 
      }
    end
  end

#-------------------------

  def downloadOld
  	dataset = Dataset.find(params[:id])
  	filename = gen_filename(dataset)

  	cells = DatasetCell.includes(:dataset_value, :dataset_link).where({dataset_id: params[:id]}).order(row: :asc, col: :asc)
  	rows = []
  	currentRowIndex = -1;
  	cells.each{ |cell|
  		if (cell.row != currentRowIndex)
  			currentRowIndex = cell.row
  			rows.push([])
  		end
      if (cell.scraped_attribute == Scraped::TEXT)
        rows[currentRowIndex].push(cell.dataset_value.text)
  		elsif (cell.scraped_attribute == Scraped::LINK)
        rows[currentRowIndex].push(cell.dataset_link.link)
      else
        # for now, default to putting the text in
        rows[currentRowIndex].push(cell.dataset_value.text)
      end
  	}

  	@rows = rows

    response.headers['Content-Type'] = 'text/csv'
    response.headers['Content-Disposition'] = 'attachment; filename=' + filename + '.csv'    
    render :template => "datasets/download.csv.erb"

  end


  def downloaddetailed
  	dataset = Dataset.find(params[:id])
  	filename = gen_filename(dataset)

  	cells = DatasetCell.includes(:dataset_value, :dataset_link).where({dataset_id: params[:id]}).order(row: :asc, col: :asc, created_at: :asc, scraped_timestamp: :asc)
  	laterCells = [] # this is a gross way to handle the fact that different passes through a dataset generate the same indexes, so just sorting by row and column isn't enough.  todo: do something better


    rows = []
    removedCellsCount = 0
    while (cells.length > 0)
      #puts "starting while again"

      if (cells[0].row != 0 || cells[0].col != 0)
        puts "throwing away a cell because it's suppsoed to be the start of a fresh pass, but it's not at position 0,0"
        puts cells[0]
        cells = cells[1..-1]
        next
      end

  	currentRowIndex = -1
        currentColumnIndex = -1
        prevCell = nil
        fullDatasetRowIndex = rows.length - 1
  	cells.each{ |cell|
                # puts "row " +  cell.row.to_s + " col " + cell.col.to_s + " ri " + currentRowIndex.to_s + " ci " + currentColumnIndex.to_s + " fdri " + fullDatasetRowIndex.to_s + " created_at " + cell.created_at.to_s
                if (cell.row == currentRowIndex && cell.col == currentColumnIndex)
                  # ok, this is a repeat cell, must have gotten it in multiple passes
                  # first let's check if it's even a different cell; if it was created at the same time, can just skip it forever
                  # if not created at the same time, have to handle it later
                  # not actually pleased with created_at as a way to handle this; todo:  look at values?  something else?; really just need a pass id on cells
                  if (cell.scraped_timestamp == prevCell.scraped_timestamp && cell.dataset_value_id == prevCell.dataset_value_id && cell.dataset_link_id == prevCell.dataset_link_id && cell.scraped_attribute == prevCell.scraped_attribute)
                    puts "removing cell for being a duplicate", cell
                    removedCellsCount += 1
                  else
                    laterCells.push(cell)
                  end
                  next
                end

                if prevCell
                  # also want to skip if there's an unreasonable gap between when cells created in a row.  all row cells are stored at same time (sent in same request).  shouldn't be 10 min gap
                  if (cell.row == prevCell.row && (cell.created_at - prevCell.created_at).abs > 600)
                    laterCells.push(cell)
                    next
                  end
                  # todo: this is bad, but also want to skip if any gap is bigger than one day.  solves problem for now.  do better in future
        
                  if ((cell.created_at - prevCell.created_at).abs > 60 * 60 * 24)
                    laterCells.push(cell)
                    next
                  end
                end

        
                prevCell = cell

        

  		if (cell.row != currentRowIndex)
  			currentRowIndex = cell.row
  			rows.push([])
                        fullDatasetRowIndex += 1
  		end
                currentColumnIndex = cell.col


      if (cell.scraped_attribute == Scraped::TEXT)
        rows[fullDatasetRowIndex].push(cell.dataset_value.text)
  		elsif (cell.scraped_attribute == Scraped::LINK)
        rows[fullDatasetRowIndex].push(cell.dataset_link.link)
      else
        # for now, default to putting the text in
        rows[fullDatasetRowIndex].push(cell.dataset_value.text)
      end

      rows[fullDatasetRowIndex].push(cell.scraped_timestamp.to_i)
  	}
      cells = laterCells
      laterCells = []
end
    puts removedCellsCount

  	@rows = rows

    response.headers['Content-Type'] = 'text/csv'
    response.headers['Content-Disposition'] = 'attachment; filename=' + filename + '.csv'    
    render :template => "datasets/download.csv.erb"

  end

  def downloadmultipass
    dataset = Dataset.find(params[:id])
    filename = gen_filename(dataset)

    cells = DatasetCell.includes(:dataset_value, :dataset_link).where({dataset_id: params[:id]}).order(pass_timestamp: :asc, row: :asc, col: :asc)

    
    rows = []
    currentRowIndex = -1
        prevTimeStamp = -1
        currentPassTimeStamp = -1
        currentBaseLength = rows.length
    cells.each{ |cell|
      if (cell.row + currentBaseLength != currentRowIndex)

                  # before we add a fresh row, let's add the pass timestamp (which is also the pass identifier) to the row
                  if (currentRowIndex >= 0)
                    # puts "pushing currentPassTimeStamp bc cell.row is new", cell.row, cell.col, "****"
                    rows[currentRowIndex].push(currentPassTimeStamp.to_i)
                  end

                  if (cell.pass_timestamp != currentPassTimeStamp)
                       # remember that each individual pass will start at row 0 again
                       # we're about to swap to a new one
                       currentBaseLength = rows.length
                       currentPassTimeStamp = cell.pass_timestamp
                    end

                   # ok, now add a new row
                    currentRowIndex = cell.row + currentBaseLength
                  # puts "new currentRowIndex", currentRowIndex
          rows.push([])
      end

      # puts rows.length, currentRowIndex, "****"
      # for now again just add both
      if (cell.scraped_attribute == Scraped::TEXT)
        rows[currentRowIndex].push(cell.dataset_value.text)
     elsif (cell.scraped_attribute == Scraped::LINK)
        rows[currentRowIndex].push(cell.dataset_link.link)
      else
        # for now, default to putting the text in
        rows[currentRowIndex].push(cell.dataset_value.text)
      end

      #rows[currentRowIndex].push(cell.scraped_timestamp.to_i)
    }

        # puts "pushing the last timestamp for last row"
        # and let's add the pass timestamp for that last row
        #rows[currentRowIndex].push(currentPassTimeStamp.to_i)

    @rows = rows

    response.headers['Content-Type'] = 'text/csv'
    response.headers['Content-Disposition'] = 'attachment; filename=' + filename + '.csv'    
    render :template => "datasets/download.csv.erb"

  end

  def downloadmultipassforgiving
    dataset = Dataset.find(params[:id])
    filename = gen_filename(dataset)

    cells = DatasetCell.includes(:dataset_value, :dataset_link).where({dataset_id: params[:id]}).order(pass_timestamp: :asc, row: :asc, col: :asc)

    
    rows = []
    currentRowIndex = -1
        prevTimeStamp = -1
        currentPassTimeStamp = -1
        currentBaseLength = rows.length
    currentCellRowIndex = -1
    cells.each{ |cell|
      if (cell.row != currentCellRowIndex)

                  # before we add a fresh row, let's add the pass timestamp (which is also the pass identifier) to the row
                  if (currentRowIndex >= 0)
                    # puts "pushing currentPassTimeStamp bc cell.row is new", cell.row, cell.col, "****"
                    rows[currentRowIndex].push(currentPassTimeStamp.to_i)
                  end

                  if (cell.pass_timestamp != currentPassTimeStamp)
                       # remember that each individual pass will start at row 0 again
                       # we're about to swap to a new one
                       currentBaseLength = rows.length
                       currentPassTimeStamp = cell.pass_timestamp
                    end

                   # ok, now add a new row
                    currentRowIndex += 1
                    currentCellRowIndex = cell.row
                  # puts "new currentRowIndex", currentRowIndex
          rows.push([])
      end

      # puts rows.length, currentRowIndex, "****"
      # for now again just add both
      if (cell.scraped_attribute == Scraped::TEXT)
        rows[currentRowIndex].push(cell.dataset_value.text)
     elsif (cell.scraped_attribute == Scraped::LINK)
        rows[currentRowIndex].push(cell.dataset_link.link)
      else
        # for now, default to putting the text in
        rows[currentRowIndex].push(cell.dataset_value.text)
      end

      #rows[currentRowIndex].push(cell.scraped_timestamp.to_i)
    }

        # puts "pushing the last timestamp for last row"
        # and let's add the pass timestamp for that last row
        #rows[currentRowIndex].push(currentPassTimeStamp.to_i)

    @rows = rows

    response.headers['Content-Type'] = 'text/csv'
    response.headers['Content-Disposition'] = 'attachment; filename=' + filename + '.csv'    
    render :template => "datasets/download.csv.erb"

  end

  def downloaddetailedmultipass
  	dataset = Dataset.find(params[:id])
  	filename = gen_filename(dataset)

  	cells = DatasetCell.includes(:dataset_value, :dataset_link).where({dataset_id: params[:id]}).order(pass_timestamp: :asc, row: :asc, col: :asc)

    
    rows = []
  	currentRowIndex = -1
        prevTimeStamp = -1
        currentPassTimeStamp = -1
        currentBaseLength = rows.length
  	cells.each{ |cell|
  		if (cell.row + currentBaseLength != currentRowIndex)

                  # before we add a fresh row, let's add the pass timestamp (which is also the pass identifier) to the row
                  if (currentRowIndex >= 0)
                    # puts "pushing currentPassTimeStamp bc cell.row is new", cell.row, cell.col, "****"
                    rows[currentRowIndex].push(currentPassTimeStamp.to_i)
                  end

                  if (cell.pass_timestamp != currentPassTimeStamp)
                       # remember that each individual pass will start at row 0 again
                       # we're about to swap to a new one
                       currentBaseLength = rows.length
                       currentPassTimeStamp = cell.pass_timestamp
                    end

                   # ok, now add a new row
                    currentRowIndex = cell.row + currentBaseLength
                  # puts "new currentRowIndex", currentRowIndex
  		    rows.push([])
  		end

      # puts rows.length, currentRowIndex, "****"
      # for now again just add both
      #if (cell.scraped_attribute == Scraped::TEXT)
        rows[currentRowIndex].push(cell.dataset_value.text)
  #		elsif (cell.scraped_attribute == Scraped::LINK)
        rows[currentRowIndex].push(cell.dataset_link.link)
   #   else
        # for now, default to putting the text in
    #    rows[currentRowIndex].push(cell.dataset_value.text)
      #end

      rows[currentRowIndex].push(cell.scraped_timestamp.to_i)
  	}

        # puts "pushing the last timestamp for last row"
        # and let's add the pass timestamp for that last row
        rows[currentRowIndex].push(currentPassTimeStamp.to_i)

  	@rows = rows

    response.headers['Content-Type'] = 'text/csv'
    response.headers['Content-Disposition'] = 'attachment; filename=' + filename + '.csv'    
    render :template => "datasets/download.csv.erb"

  end


  def downloaddetailedallattributes
  	dataset = Dataset.find(params[:id])
  	filename = gen_filename(dataset)

  	cells = DatasetCell.includes(:dataset_value, :dataset_link).where({dataset_id: params[:id]}).order(row: :asc, col: :asc)
  	rows = []
  	currentRowIndex = -1;
  	cells.each{ |cell|
  		if (cell.row != currentRowIndex)
  			currentRowIndex = cell.row
  			rows.push([])
  		end

      # just go ahead and put in both text and link
        rows[currentRowIndex].push(cell.dataset_value.text)
        rows[currentRowIndex].push(cell.dataset_link.link)

      rows[currentRowIndex].push(cell.scraped_timestamp.to_i)
  	}

  	@rows = rows

    response.headers['Content-Type'] = 'text/csv'
    response.headers['Content-Disposition'] = 'attachment; filename=' + filename + '.csv'    
    render :template => "datasets/download.csv.erb"

  end

  def downloadforgiving
  	dataset = Dataset.find(params[:id])
  	filename = gen_filename(dataset)

  	cells = DatasetCell.includes(:dataset_value, :dataset_link).where({dataset_id: params[:id]}).order(row: :asc, col: :asc)
  	rows = []
  	currentRowIndex = -1
    currentDatasetRowIndex = -1
  	cells.each{ |cell|
  		if (cell.row != currentDatasetRowIndex)
        if (!cell.row)
          puts "bad cell:", cell
          next
        end
  			currentRowIndex += 1
        currentDatasetRowIndex = cell.row
        rows.push([])
  		end
      if (cell.scraped_attribute == Scraped::TEXT)
        rows[currentRowIndex].push(cell.dataset_value.text)
      elsif (cell.scraped_attribute == Scraped::LINK)
        rows[currentRowIndex].push(cell.dataset_link.link)
      else
        # for now, default to putting the text in
        rows[currentRowIndex].push(cell.dataset_value.text)
      end
  	}

  	@rows = rows

    response.headers['Content-Type'] = 'text/csv'
    response.headers['Content-Disposition'] = 'attachment; filename=' + filename + '.csv'    
    render :template => "datasets/download.csv.erb"

  end

end
